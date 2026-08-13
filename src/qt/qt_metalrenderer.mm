/*
 * 86Box    Metal renderer (Apple only) — implementation.
 *
 *          QWindow shell: attaches a CAMetalLayer to the window's NSView and
 *          drives MetalPresenter from 86Box's blit callbacks. Mirrors the
 *          OpenGL/Vulkan window renderers' lifecycle (lazy init on first
 *          expose, two CPU buffers exposed via getBuffers, rendererInitialized
 *          signal once live).
 */
#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

#include "qt_metalrenderer.hpp"
#include "metal_presenter.h"

#include <QApplication>
#include <QResizeEvent>
#include <QTimerEvent>
#include <QScreen>
#include <QDialog>
#include <QFormLayout>
#include <QSlider>
#include <QComboBox>
#include <QCheckBox>
#include <QLabel>
#include <QDialogButtonBox>
#include <algorithm>
#include <cmath>

#include <cstdio>
#include <functional>

extern "C" {
#include <86box/video.h>
}

MetalRenderer::MetalRenderer(QWidget *parent)
    : QWindow()
    , presenter(std::make_unique<MetalPresenter>())
{
    // Deliberately NOT a MetalSurface: we host our own CAMetalLayer on a child
    // NSView (see initialize()) rather than letting Qt's QNSView own/drive a
    // Metal layer via displayLayer:, which collides with our presentDrawable
    // and crashes. Leave the QWindow as the default surface.
    RendererCommon::parentWidget = parent;

    imagebufs[0] = std::make_unique<uint8_t[]>(2048 * 2048 * 4);
    imagebufs[1] = std::make_unique<uint8_t[]>(2048 * 2048 * 4);
    buf_usage    = std::vector<std::atomic_flag>(2);
    buf_usage[0].clear();
    buf_usage[1].clear();
}

MetalRenderer::~MetalRenderer()
{
    // The notification blocks capture `this`; they must never outlive it.
    stopDisplayObservers();
}

uint32_t
MetalRenderer::getBytesPerRow()
{
    return 2048 * 4;
}

std::vector<std::tuple<uint8_t *, std::atomic_flag *>>
MetalRenderer::getBuffers()
{
    std::vector<std::tuple<uint8_t *, std::atomic_flag *>> buffers;
    buffers.push_back(std::make_tuple(imagebufs[0].get(), &buf_usage[0]));
    buffers.push_back(std::make_tuple(imagebufs[1].get(), &buf_usage[1]));
    return buffers;
}

void
MetalRenderer::initialize()
{
    if (isInitialized || initFailed)
        return;

    // winId() on macOS is Qt's backing NSView. Rather than touch its layer
    // (which Qt manages and drives via displayLayer:), host our CAMetalLayer on
    // a dedicated child NSView. Qt's view is left entirely alone, so its display
    // machinery never dispatches into our Metal layer — no collision, no crash.
    NSView *qtView = reinterpret_cast<NSView *>(winId());
    if (qtView == nil) {
        initFailed = true;
        emit errorInitializing();
        return;
    }
    NSView *metalView = [[NSView alloc] initWithFrame:qtView.bounds];
    metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    metalView.wantsLayer       = YES;
    CAMetalLayer *layer        = [CAMetalLayer layer];
    metalView.layer            = layer;       // our view owns it; Qt is not the delegate
    [qtView addSubview:metalView];            // retains metalView

    if (!presenter->init((__bridge void *) layer)) {
        initFailed = true;
        emit errorInitializing();
        return;
    }

    isInitialized = true;
    updateDrawableSize();

    // Turn on the CRT simulation. Content size is corrected on the first blit;
    // 640x480 is just a seed. No-op in stub builds (returns false) — we then
    // present straight, exactly as before.
    presenter->enableCRT("VGA monitor", 640, 480);

    // Report the physical display to the engine, and keep reporting it: the panel is
    // not a constant. The user can drag the window to a different monitor, change the
    // resolution or scaled mode, plug in an external display, or turn HDR on — and
    // CRTEngine's mask pitch and render resolution are all anchored to the panel, so
    // a stale report means it is rendering for a display that is no longer there.
    reportDisplay();
    startDisplayObservers();

    fprintf(stderr, "[MetalRenderer] renderer initialized for monitor %d (%dx%d), CRT=%s\n",
            r_monitor_index, int(width()), int(height()),
            presenter->crtEnabled() ? "on" : "stub");
    emit rendererInitialized();
}

void
MetalRenderer::updateDrawableSize()
{
    if (!isInitialized)
        return;
    const qreal dpr = devicePixelRatio();
    // Pin the layer's contentsScale to the backing scale BEFORE sizing the
    // drawable, so drawableSize == bounds * contentsScale and Core Animation
    // presents the drawable 1:1 (no resample moiré on the fine CRT detail).
    presenter->setContentsScale(dpr);
    presenter->resizeDrawable(int(width() * dpr), int(height() * dpr));
}

/* ---- Physical display: gather + report (the host's whole job here) --------------
   The division of labour (CRTEngine docs/RenderIntent-DisplayVsRecording.md §1): the
   host reports WHAT the display is; the engine decides HOW to render for it. So this
   makes no rendering decisions — it hands over the NSScreen and lets CRTEngine
   re-derive phosphor pitch, render resolution, mask LOD and HDR dimming itself. */

/* Same file log as the signal diagnostics: a Finder-launched .app has nowhere to put
   stderr. Display changes are rare, so the open/close per line is free. */
static void
logDisplay(NSScreen *s, double scale)
{
    const char *home = getenv("HOME");
    if (home == nullptr)
        return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/Library/Logs/86Box-crt-signal.log", home);
    FILE *f = fopen(path, "a");
    if (f == nullptr)
        return;
    const NSRect fr = s.frame;
    fprintf(f, "display -> \"%s\" %.0fx%.0f pts @%.1fx  EDR now %.2f / potential %.2f\n",
            s.localizedName.UTF8String, fr.size.width, fr.size.height, scale,
            s.maximumExtendedDynamicRangeColorComponentValue,
            s.maximumPotentialExtendedDynamicRangeColorComponentValue);
    fclose(f);
}

void
MetalRenderer::reportDisplay()
{
    if (!isInitialized)
        return;

    NSView *qtView = reinterpret_cast<NSView *>(winId());
    NSScreen *nsScreen = qtView.window.screen ?: NSScreen.mainScreen;
    if (nsScreen == nil)
        return;

    logDisplay(nsScreen, nsScreen.backingScaleFactor);

    // Backing scale can change with the display (Retina <-> non-Retina), so re-pin the
    // layer's contentsScale and drawable size before reporting.
    updateDrawableSize();

    if (screen())
        presenter->setDisplayRefresh(float(screen()->refreshRate()));
    presenter->updateDisplay((__bridge void *) nsScreen);

    lastEdrHeadroom = nsScreen.maximumExtendedDynamicRangeColorComponentValue;
}

void
MetalRenderer::startDisplayObservers()
{
    NSView *qtView = reinterpret_cast<NSView *>(winId());
    NSWindow *win  = qtView.window;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

    // Fires for resolution / scaled-mode changes, display arrangement changes, and
    // monitors being connected or disconnected.
    obsScreenParams = (__bridge_retained void *) [nc
        addObserverForName:NSApplicationDidChangeScreenParametersNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *) { reportDisplay(); }];

    // The window was dragged onto a different display.
    obsWindowScreen = (__bridge_retained void *) [nc
        addObserverForName:NSWindowDidChangeScreenNotification
                    object:win
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *) { reportDisplay(); }];

    // Backing scale factor changed (e.g. moved between a Retina and a 1x display).
    obsBackingProps = (__bridge_retained void *) [nc
        addObserverForName:NSWindowDidChangeBackingPropertiesNotification
                    object:win
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *) { reportDisplay(); }];

    // EDR headroom has NO notification — it drifts with screen brightness and with
    // HDR content appearing elsewhere on the display. Poll it; it is one cheap
    // property read, and we only re-report when it actually moves.
    edrPollTimer = startTimer(1000);
}

void
MetalRenderer::stopDisplayObservers()
{
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (obsScreenParams != nullptr) {
        [nc removeObserver:(__bridge_transfer id) obsScreenParams];
        obsScreenParams = nullptr;
    }
    if (obsWindowScreen != nullptr) {
        [nc removeObserver:(__bridge_transfer id) obsWindowScreen];
        obsWindowScreen = nullptr;
    }
    if (obsBackingProps != nullptr) {
        [nc removeObserver:(__bridge_transfer id) obsBackingProps];
        obsBackingProps = nullptr;
    }
    if (edrPollTimer != 0) {
        killTimer(edrPollTimer);
        edrPollTimer = 0;
    }
}

void
MetalRenderer::timerEvent(QTimerEvent *event)
{
    if (event->timerId() != edrPollTimer) {
        QWindow::timerEvent(event);
        return;
    }
    if (!isInitialized)
        return;

    NSView *qtView = reinterpret_cast<NSView *>(winId());
    NSScreen *nsScreen = qtView.window.screen ?: NSScreen.mainScreen;
    if (nsScreen == nil)
        return;

    const double edr = nsScreen.maximumExtendedDynamicRangeColorComponentValue;
    if (std::fabs(edr - lastEdrHeadroom) > 0.05)   // real change, not float noise
        reportDisplay();
}

void
MetalRenderer::onBlit(int buf_idx, int x, int y, int w, int h)
{
    if (!isInitialized || buf_idx < 0 || buf_idx > 1) {
        // Still release the buffer the blitter handed us.
        buf_usage[buf_idx ^ 1].clear();
        return;
    }

    presenter->upload(imagebufs[buf_idx].get(), x, y, w, h, getBytesPerRow());

    // The emulated card's TRUE vertical refresh, straight from its CRTC. The bridge
    // is a video card and a cable: it reports what the card is really sending and
    // never invents it. 0 = this card doesn't report timings (CGA/MDA/EGA today).
    presenter->setSignalRefresh(float(monitors[r_monitor_index].mon_signal_refresh_hz));

    // Done with this buffer; free the other for the blit thread (matches the
    // software/opengl handshake: clear the *other* flag).
    buf_usage[buf_idx ^ 1].clear();

    source.setRect(x, y, w, h);
    presenter->present(x, y, w, h);
}

void
MetalRenderer::exposeEvent(QExposeEvent *event)
{
    Q_UNUSED(event);
    if (isExposed())
        initialize();
}

void
MetalRenderer::resizeEvent(QResizeEvent *event)
{
    onResize(event->size().width(), event->size().height());
    updateDrawableSize();
    QWindow::resizeEvent(event);
}

bool
MetalRenderer::event(QEvent *event)
{
    bool res = false;
    if (eventDelegate(event, res))
        return res;
    return QWindow::event(event);
}

void
MetalRenderer::finalize()
{
    // Presenter teardown is handled by its destructor; nothing async to flush.
}

bool
MetalRenderer::hasOptions() const
{
    return presenter && presenter->crtEnabled();
}

// A labeled horizontal slider mapping an integer track to a float range. The
// signal is connected AFTER the initial value is set, so merely opening the
// dialog doesn't perturb the engine's current settings.
static void
addSlider(QFormLayout *form, const QString &label, double lo, double hi,
          double init, std::function<void(float)> setter)
{
    auto *s = new QSlider(Qt::Horizontal);
    s->setRange(0, 1000);
    s->setValue(int((init - lo) / (hi - lo) * 1000.0));
    QObject::connect(s, &QSlider::valueChanged, [=](int v) {
        setter(float(lo + (hi - lo) * (double) v / 1000.0));
    });
    form->addRow(label, s);
}

static void
addSection(QFormLayout *form, const QString &title)
{
    auto *l = new QLabel(QStringLiteral("<b>%1</b>").arg(title));
    l->setContentsMargins(0, 8, 0, 2);
    form->addRow(l);
}

QDialog *
MetalRenderer::getOptions(QWidget *parent)
{
    MetalPresenter *p = presenter.get();
    auto *dlg = new QDialog(parent);
    dlg->setWindowTitle(tr("CRT Monitor Options"));
    auto *form = new QFormLayout(dlg);

    // Initialize each control to the persisted value (or the nominal default).
    // CRT preset — highest-level choice. Combo order MUST match kCrtPresetNames in
    // metal_presenter.mm (0=Green … 5=VGA monitor).
    auto *preset = new QComboBox();
    preset->addItems({ tr("Green monitor"), tr("Amber monitor"), tr("White monitor"),
                       tr("NTSC B&W TV"), tr("NTSC color TV"), tr("VGA monitor") });
    preset->setCurrentIndex(std::clamp(int(std::lround(p->persistedValue("crt.preset", 5))), 0, 5));
    QObject::connect(preset, QOverload<int>::of(&QComboBox::currentIndexChanged),
                     [p](int idx) { p->setPreset(idx); });
    form->addRow(tr("CRT preset"), preset);

    addSection(form, tr("Picture"));
    addSlider(form, tr("Brightness"), -0.4, 0.5, p->persistedValue("crt.brightness", 0.0),  [p](float v) { p->setBrightness(v); });
    addSlider(form, tr("Contrast"),    0.1, 3.0, p->persistedValue("crt.contrast", 1.5),    [p](float v) { p->setContrast(v); });

    addSection(form, tr("HDR"));
    // EDR is headroom for the tube's PEAKS, not a picture gain: the picture body is
    // identity on every panel; only >reference-white content (mask sparkle, highlights)
    // rises into the panel's measured headroom, capped by this allowance. 1.0 = SDR look.
    addSlider(form, tr("Peak highlights (SDR ↔ full)"), 1.0, 8.0, p->persistedValue("crt.peaks", 2.5), [p](float v) { p->setPeakHighlights(v); });
    // (No "Mask softening" control: as of CRTEngine 1.4.0 the display shader's automatic
    // Nyquist band-limit flattens the mask on its own when it can't be resolved, so the
    // manual HDR mask-dim was redundant.)

    addSection(form, tr("Phosphor"));
    auto *pattern = new QComboBox();
    pattern->addItems({ tr("Triode (delta)"), tr("Stripe (aperture grille)"),
                        tr("Shadow mask"), tr("Slot mask") });
    pattern->setCurrentIndex(int(p->persistedValue("crt.pattern", 1)));   // VGA preset = stripe
    QObject::connect(pattern, QOverload<int>::of(&QComboBox::currentIndexChanged),
                     [p](int idx) { p->setPhosphorPattern(idx); });
    form->addRow(tr("Pattern"), pattern);

    // RGB mask scale (Pattern Scale) — 1× is the tube's real physical phosphor pitch; higher
    // coarsens the grille so it reads at smaller window sizes (a fine VGA tube is sub-Nyquist
    // at typical sizes and needs several ×). CRTEngine 1.4.0 supports 1–10×.
    addSlider(form, tr("RGB scale (1–10×)"), 1.0, 10.0, p->persistedValue("crt.maskscale", 1.0), [p](float v) { p->setMaskScale(v); });


    addSection(form, tr("Beam"));
    addSlider(form, tr("Sharpness (soft ↔ sharp)"), 0.0, 1.0, p->persistedValue("crt.sharpness", 0.5), [p](float v) { p->setSharpness(v); });
    // Video bandwidth: the analog-chain reconstruction rolloff β. LOWER = wider flat
    // passband = crisper horizontal detail (with more sinc-ringing on hard edges);
    // HIGHER = softer, less ringing. 0 drops the reconstruction entirely for a
    // ringless (but resample-beat-unprotected) pristine-VGA look — the anti-banding
    // reconstruction is no longer forced always-on; it's the user's trade-off.
    addSlider(form, tr("Video bandwidth (crisp ↔ soft)"), 0.0, 1.0, p->persistedValue("crt.hbandwidth", 0.5), [p](float v) { p->setHBandwidth(v); });
    // Optical horizontal defocus of the beam spot, in source pixels. 0 = focused.
    // Bipolar like the real focus pot: 0 = sweet spot, either direction blurs.
    addSlider(form, tr("H focus (◄ 0 ►)"), -3.0, 3.0, p->persistedValue("crt.hfocus", 0.0), [p](float v) { p->setHFocus(v); });
    // (Beam sweep dial removed: the beam is pinned to the dot — the tube's
    // physical truth. The user-facing control is the OBSERVER:)
    // 1 = fused eye (steady), lower = camera shutter — the rolling band /
    // flicker of filmed CRT footage.
    addSlider(form, tr("Shutter (camera ↔ eye)"), 0.0, 1.0, p->persistedValue("crt.shutter", 1.0), [p](float v) { p->setShutter(v); });
    // (Scanline smoothing + Pattern smoothing sliders removed: they dialed
    // display-shader anti-alias parameters, not tube physics — simulation-first
    // cleanup. Engine defaults stay active internally.)
    addSlider(form, tr("Edge focus loss"),      0.0, 1.0,  p->persistedValue("crt.edge", 0.21),  [p](float v) { p->setEdgeFocus(v); });
    addSlider(form, tr("Bloom"),                0.0, 0.5,  p->persistedValue("crt.bloom", 0.0),  [p](float v) { p->setBloom(v); });
    addSlider(form, tr("Convergence (◄ 0 ►)"), -10.0, 10.0, p->persistedValue("crt.convergence", 0.0), [p](float v) { p->setConvergence(v); });

    addSection(form, tr("Monitor conditions"));
    addSlider(form, tr("H-jitter"),     0.0, 3.0,  p->persistedValue("crt.hjitter", 0.0),     [p](float v) { p->setHJitter(v); });
    addSlider(form, tr("V-jitter"),     0.0, 2.0,  p->persistedValue("crt.vjitter", 0.0),     [p](float v) { p->setVJitter(v); });
    addSlider(form, tr("Shot noise"),   0.0, 0.05, p->persistedValue("crt.shotnoise", 0.0),   [p](float v) { p->setShotNoise(v); });
    addSlider(form, tr("Signal noise"), 0.0, 0.15, p->persistedValue("crt.signalnoise", 0.0), [p](float v) { p->setSignalNoise(v); });

    auto *buttons = new QDialogButtonBox(QDialogButtonBox::Close);
    QObject::connect(buttons, &QDialogButtonBox::rejected, dlg, &QDialog::accept);
    form->addRow(buttons);

    return dlg;
}
