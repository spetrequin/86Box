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

MetalRenderer::~MetalRenderer() = default;

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
    if (screen())
        presenter->setDisplayRefresh(float(screen()->refreshRate()));
    // Feed host-display capabilities (EDR/HDR headroom, refresh) to the engine.
    presenter->updateDisplay((__bridge void *) qtView.window.screen);

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

void
MetalRenderer::onBlit(int buf_idx, int x, int y, int w, int h)
{
    if (!isInitialized || buf_idx < 0 || buf_idx > 1) {
        // Still release the buffer the blitter handed us.
        buf_usage[buf_idx ^ 1].clear();
        return;
    }

    presenter->upload(imagebufs[buf_idx].get(), x, y, w, h, getBytesPerRow());

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
    auto *hdrEnable = new QCheckBox();
    hdrEnable->setChecked(p->persistedValue("crt.hdrenabled", 1.0) != 0.0);
    QObject::connect(hdrEnable, &QCheckBox::toggled, [p](bool on) { p->setHdrEnabled(on); });
    form->addRow(tr("Enable HDR"), hdrEnable);
    // Softens the phosphor mask as EDR headroom rises, so it doesn't read as a harsh
    // crosshatch on HDR panels. 0 = crisp (may be harsh), 1 = strongly softened.
    addSlider(form, tr("Mask softening"), 0.0, 1.0, p->persistedValue("crt.hdrmaskdim", 0.5), [p](float v) { p->setHdrMaskDim(v); });

    addSection(form, tr("Phosphor"));
    auto *pattern = new QComboBox();
    pattern->addItems({ tr("Triode (delta)"), tr("Stripe (aperture grille)"),
                        tr("Shadow mask"), tr("Slot mask") });
    pattern->setCurrentIndex(int(p->persistedValue("crt.pattern", 1)));   // VGA preset = stripe
    QObject::connect(pattern, QOverload<int>::of(&QComboBox::currentIndexChanged),
                     [p](int idx) { p->setPhosphorPattern(idx); });
    form->addRow(tr("Pattern"), pattern);

    // RGB mask scale — 1× is the algorithmic finest (1 panel px per stripe); 2×/3×
    // coarsen it. Maps to the engine's displayMaskScale multiplier.
    auto *rgbScale = new QComboBox();
    rgbScale->addItems({ tr("1× (finest)"), tr("2×"), tr("3×") });
    rgbScale->setCurrentIndex(std::clamp(int(std::lround(p->persistedValue("crt.maskscale", 1.0))) - 1, 0, 2));
    QObject::connect(rgbScale, QOverload<int>::of(&QComboBox::currentIndexChanged),
                     [p](int idx) { p->setMaskScale(float(idx + 1)); });
    form->addRow(tr("RGB scale"), rgbScale);

    addSection(form, tr("Beam"));
    addSlider(form, tr("Sharpness (soft ↔ sharp)"), 0.0, 1.0, p->persistedValue("crt.sharpness", 0.5), [p](float v) { p->setSharpness(v); });
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
