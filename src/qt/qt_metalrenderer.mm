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
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QGridLayout>
#include <QTabWidget>
#include <QSlider>
#include <QComboBox>
#include <QLabel>
#include <QToolButton>
#include <QPushButton>
#include <QDialogButtonBox>
#include <QSignalBlocker>
#include <QTimer>
#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <vector>

#include <cstdio>

#ifdef USE_CRTENGINE
#    include "crt_bridge.h"   // CRTDial — the dial identifiers; nothing else is called from here
#endif

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
    // Log a display when it CHANGES, not every time it is reported. The current EDR
    // headroom drifts continuously and each drift is a report (see reportDisplay), so an
    // unfiltered log is mostly this one line; a quarter-stop of headroom is the smallest
    // move worth a line.
    static std::string lastName;       // (not an NSString: these files build without ARC)
    static NSRect      lastFrame;
    static double    lastScale = 0.0, lastNow = -1.0, lastPotential = -1.0;
    const double now       = s.maximumExtendedDynamicRangeColorComponentValue;
    const double potential = s.maximumPotentialExtendedDynamicRangeColorComponentValue;
    const std::string name = s.localizedName.UTF8String ?: "";
    if (lastNow >= 0.0 && lastName == name
        && NSEqualRects(lastFrame, s.frame) && lastScale == scale
        && lastPotential == potential && std::fabs(now - lastNow) < 0.25)
        return;
    lastName      = name;
    lastFrame     = s.frame;
    lastScale     = scale;
    lastNow       = now;
    lastPotential = potential;

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

/* ---- CRT Monitor Options ----------------------------------------------------------
   The dialog is a VIEW of the engine, not a second copy of it. Preset names, each
   dial's range, where the live preset starts a dial and where it sits now are all read
   from CRTEngine through the presenter; what lives here is only what a host owns —
   labels, grouping, units and help text. So a slider cannot open on a guessed default
   or offer a range the engine would clamp, and the engine adding a preset needs no
   edit here. Changes apply live and persist; closing the dialog is not a commit. */
#ifdef USE_CRTENGINE
namespace {

/* What the host decides about a dial: its name, how its value reads, and when it means
   anything. Which dial, its range and its values are the engine's. */
struct DialSpec {
    enum Needs { Always, Color, Pattern };   // Pattern = a colour tube showing a mask
    int         dial;
    QString     label;
    const char *format;    // printf format for (value * scale)
    double      scale;     // display multiplier (100 for a fraction shown as percent)
    Needs       needs;
    QString     help;
};

struct DialRow {
    DialSpec     spec;
    float        lo = 0.0f, hi = 1.0f;
    QLabel      *name   = nullptr;
    QSlider     *slider = nullptr;
    QLabel      *value  = nullptr;
    QToolButton *reset  = nullptr;
};

const int kTrack = 1000;   // slider resolution across a dial's travel

struct OptionsUI {
    MetalPresenter      *p = nullptr;
    std::vector<DialRow> rows;
    QComboBox           *preset  = nullptr;
    QComboBox           *pattern = nullptr;
    QLabel              *status  = nullptr;

    static int toTrack(const DialRow &r, float v)
    {
        if (r.hi <= r.lo)
            return 0;
        return std::clamp(int(std::lround((v - r.lo) / (r.hi - r.lo) * kTrack)), 0, kTrack);
    }

    /* Show one dial as the engine has it. Signals are blocked so that reading the
       engine can never write back to it. */
    void show(DialRow &r)
    {
        const float v = p->dial(r.spec.dial);
        {
            const QSignalBlocker block(r.slider);
            r.slider->setValue(toTrack(r, v));
        }
        r.value->setText(QString::asprintf(r.spec.format, double(v) * r.spec.scale));
        // The reset arrow lights up only for a dial the user has moved off the preset,
        // which makes it double as the "what have I changed?" indicator.
        r.reset->setEnabled(p->dialIsSet(r.spec.dial));

        const bool color   = p->isColor();
        const bool applies = r.spec.needs == DialSpec::Always
                          || (r.spec.needs == DialSpec::Color && color)
                          || (r.spec.needs == DialSpec::Pattern && color && p->phosphorPattern() != 0);
        r.name->setEnabled(applies);
        r.slider->setEnabled(applies);
        r.value->setEnabled(applies);
    }

    void refresh()
    {
        {
            const QSignalBlocker block(preset);
            preset->setCurrentIndex(p->currentPreset());
        }
        {
            const QSignalBlocker block(pattern);
            pattern->setCurrentIndex(std::clamp(p->phosphorPattern(), 0, 3));
            pattern->setEnabled(p->isColor());   // a mono tube has no mask to choose
        }
        for (auto &r : rows)
            show(r);
        status->setText(QString::fromStdString(p->status()));
    }
};

} // namespace
#endif

QDialog *
MetalRenderer::getOptions(QWidget *parent)
{
#ifdef USE_CRTENGINE
    auto ui = std::make_shared<OptionsUI>();
    ui->p   = presenter.get();

    auto *dlg = new QDialog(parent);
    dlg->setWindowTitle(tr("CRT Monitor Options"));
    auto *root = new QVBoxLayout(dlg);

    // ---- The tube ----
    auto *top = new QHBoxLayout();
    ui->preset = new QComboBox();
    for (int i = 0; i < ui->p->presetCount(); i++)
        ui->preset->addItem(QString::fromUtf8(ui->p->presetName(i)));
    auto *presetLabel = new QLabel(tr("Monitor"));
    presetLabel->setBuddy(ui->preset);
    top->addWidget(presetLabel);
    top->addWidget(ui->preset, 1);
    root->addLayout(top);

    auto *tabs = new QTabWidget();
    root->addWidget(tabs, 1);

    // One page of dial rows: name | slider | value | reset.
    auto addPage = [&](const QString &title) {
        auto *page = new QWidget();
        auto *grid = new QGridLayout(page);
        grid->setColumnStretch(1, 1);
        grid->setColumnMinimumWidth(1, 260);
        tabs->addTab(page, title);
        return grid;
    };
    // Room for the widest reading, so the sliders do not shift as values change.
    const int valueWidth = dlg->fontMetrics().horizontalAdvance(QStringLiteral("+00.00 lines"));

    auto addDial = [&](QGridLayout *grid, const DialSpec &spec) {
        DialRow r;
        r.spec = spec;
        ui->p->dialRange(spec.dial, &r.lo, &r.hi);

        r.name   = new QLabel(spec.label);
        r.slider = new QSlider(Qt::Horizontal);
        r.slider->setRange(0, kTrack);
        r.slider->setPageStep(kTrack / 20);
        r.value = new QLabel();
        r.value->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
        r.value->setMinimumWidth(valueWidth);
        r.reset = new QToolButton();
        r.reset->setText(QStringLiteral("↺"));
        r.reset->setAutoRaise(true);
        r.reset->setToolTip(tr("Back to this monitor's own setting"));
        r.name->setToolTip(spec.help);
        r.slider->setToolTip(spec.help);

        const int row = grid->rowCount();
        grid->addWidget(r.name, row, 0);
        grid->addWidget(r.slider, row, 1);
        grid->addWidget(r.value, row, 2);
        grid->addWidget(r.reset, row, 3);

        const size_t idx = ui->rows.size();
        ui->rows.push_back(r);
        QObject::connect(r.slider, &QSlider::valueChanged, dlg, [ui, idx](int t) {
            DialRow &row = ui->rows[idx];
            ui->p->setDial(row.spec.dial, row.lo + (row.hi - row.lo) * float(t) / float(kTrack));
            ui->show(row);
        });
        QObject::connect(r.reset, &QToolButton::clicked, dlg, [ui, idx]() {
            ui->p->resetDial(ui->rows[idx].spec.dial);
            ui->show(ui->rows[idx]);
        });
    };
    auto endPage = [](QGridLayout *grid) { grid->setRowStretch(grid->rowCount(), 1); };

    using D = DialSpec;

    // ---- Picture ----
    auto *picture = addPage(tr("Picture"));
    addDial(picture, { CRT_DIAL_BRIGHTNESS, tr("Brightness"), "%+.2f", 1.0, D::Always,
        tr("The black level: lifts or lowers the whole picture.") });
    addDial(picture, { CRT_DIAL_CONTRAST, tr("Contrast"), "%.2f", 1.0, D::Always,
        tr("The video gain: how hard the picture drives the tube.") });
    addDial(picture, { CRT_DIAL_SATURATION, tr("Saturation"), "%.2f", 1.0, D::Color,
        tr("Colour strength. 1.00 is the signal as sent.") });
    addDial(picture, { CRT_DIAL_PEAK_HIGHLIGHTS, tr("Peak highlights"), "%.1f×", 1.0, D::Always,
        tr("How far the tube's brightest points may rise above white on an HDR display.\n"
           "1.0× is the SDR look. The display's own headroom is always the limit, and the\n"
           "body of the picture is unchanged at any setting.") });
    endPage(picture);

    // ---- Tube: the phosphor screen and the glass in front of it ----
    auto *tube = addPage(tr("Tube"));
    ui->pattern = new QComboBox();
    ui->pattern->addItems({ tr("None (triode)"), tr("Stripe (aperture grille)"),
                            tr("Shadow mask"), tr("Slot mask") });
    ui->pattern->setToolTip(tr("The colour phosphor layout. Monochrome monitors have none."));
    {
        auto *l = new QLabel(tr("Phosphor pattern"));
        l->setBuddy(ui->pattern);
        const int row = tube->rowCount();
        tube->addWidget(l, row, 0);
        tube->addWidget(ui->pattern, row, 1, 1, 3);
    }
    addDial(tube, { CRT_DIAL_PATTERN_SCALE, tr("Pattern size"), "%.1f px", 1.0, D::Pattern,
        tr("Width of one red-green-blue group in screen pixels. Below about 3 px the\n"
           "pattern is finer than the screen can show and blends into an even sheen.") });
    addDial(tube, { CRT_DIAL_PATTERN_FOCUS, tr("Pattern focus"), "%.2f", 1.0, D::Pattern,
        tr("How tightly the beam lands on a single phosphor: higher is crisper and more\n"
           "saturated, lower is softer and fainter.") });
    addDial(tube, { CRT_DIAL_CURVATURE, tr("Glass curvature"), "%.2f", 1.0, D::Always,
        tr("0 is a flat screen, 1.00 is this tube's real curvature, above that is\n"
           "rounder than any tube that shipped.") });
    addDial(tube, { CRT_DIAL_HALATION, tr("Halation"), "%.2f", 1.0, D::Always,
        tr("The broad halo around bright areas, from light reflected back inside the\n"
           "glass. 1.00 is the amount this tube's glass really returns.") });
    addDial(tube, { CRT_DIAL_SCATTER, tr("Glass haze"), "%.2f", 1.0, D::Always,
        tr("The soft local glow of an etched, anti-glare screen surface. 0 is polished glass.") });
    addDial(tube, { CRT_DIAL_OVERSCAN, tr("Picture size"), "%+.1f %%", 100.0, D::Always,
        tr("The size control on the back of the set. Positive pushes the picture's edges\n"
           "behind the bezel (overscan); negative shrinks it inside the glass (underscan).") });
    addDial(tube, { CRT_DIAL_VIGNETTE, tr("Vignette"), "%.2f", 1.0, D::Always,
        tr("Darkening toward the edges of the screen.") });
    endPage(tube);

    // ---- Beam ----
    auto *beam = addPage(tr("Beam"));
    addDial(beam, { CRT_DIAL_SHARPNESS, tr("Sharpness"), "%.2f", 1.0, D::Always,
        tr("The beam's height. Low fills the space between scanlines; high draws thin,\n"
           "separate lines. At high resolutions the lines are too close for this to show.") });
    addDial(beam, { CRT_DIAL_H_BANDWIDTH, tr("Video bandwidth"), "%.2f", 1.0, D::Always,
        tr("How fast the video amplifier follows the signal. Lower is crisper with slight\n"
           "ringing on hard edges; higher is softer. 0 is a plain ringless spot.") });
    addDial(beam, { CRT_DIAL_H_FOCUS, tr("Focus"), "%+.2f px", 1.0, D::Always,
        tr("The focus control: 0 is in focus, and turning it either way blurs the spot.") });
    addDial(beam, { CRT_DIAL_SHUTTER, tr("Shutter"), "%.2f", 1.0, D::Always,
        tr("Who is watching. 1.00 is the eye, which sees a steady picture; lower is a\n"
           "camera with an ever faster shutter — flicker and a rolling band.") });
    addDial(beam, { CRT_DIAL_EDGE_FOCUS, tr("Edge focus loss"), "%.2f", 1.0, D::Always,
        tr("How much the beam defocuses toward the edges of the screen.") });
    addDial(beam, { CRT_DIAL_BLOOM, tr("Bloom"), "%.2f", 1.0, D::Always,
        tr("How much the beam swells in bright areas.") });
    addDial(beam, { CRT_DIAL_CONVERGENCE, tr("Convergence"), "%+.1f", 1.0, D::Color,
        tr("Misalignment of the three colour beams. 0 is converged; the sign chooses\n"
           "which way the colour fringes fall.") });
    endPage(beam);

    // ---- Signal and wear ----
    auto *wear = addPage(tr("Signal && Wear"));
    addDial(wear, { CRT_DIAL_H_JITTER, tr("Horizontal jitter"), "%.2f px", 1.0, D::Always,
        tr("Scanlines shifting sideways from line to line.") });
    addDial(wear, { CRT_DIAL_V_JITTER, tr("Vertical jitter"), "%.2f lines", 1.0, D::Always,
        tr("The whole picture bouncing from frame to frame.") });
    addDial(wear, { CRT_DIAL_SHOT_NOISE, tr("Beam noise"), "%.3f", 1.0, D::Always,
        tr("Fine grain from the beam itself.") });
    addDial(wear, { CRT_DIAL_SIGNAL_NOISE, tr("Signal noise"), "%.3f", 1.0, D::Always,
        tr("Snow on the incoming signal.") });
    endPage(wear);

    // ---- What the tube is doing ----
    // This is a diagnostic host: the numbers that explain a picture — the signal the
    // tube is locked to, the lines and buffer the engine chose, how many screen pixels
    // each scanline gets — are shown here instead of only in the log, and can be
    // selected and copied.
    ui->status = new QLabel();
    ui->status->setWordWrap(true);
    ui->status->setTextInteractionFlags(Qt::TextSelectableByMouse);
    ui->status->setEnabled(false);   // secondary text colour
    {
        QFont f = ui->status->font();
        f.setPointSizeF(f.pointSizeF() * 0.85);
        ui->status->setFont(f);
    }
    root->addWidget(ui->status);

    auto *buttons  = new QDialogButtonBox(QDialogButtonBox::Close);
    auto *resetAll = buttons->addButton(tr("Reset All to Monitor Defaults"), QDialogButtonBox::ResetRole);
    root->addWidget(buttons);

    // ---- Behaviour ----
    QObject::connect(ui->preset, QOverload<int>::of(&QComboBox::currentIndexChanged), dlg,
                     [ui](int idx) {
                         ui->p->setPreset(idx);
                         ui->refresh();   // the new tube's starting positions and applicability
                     });
    QObject::connect(ui->pattern, QOverload<int>::of(&QComboBox::currentIndexChanged), dlg,
                     [ui](int idx) {
                         ui->p->setPhosphorPattern(idx);
                         ui->refresh();   // pattern size/focus only apply with a mask
                     });
    QObject::connect(resetAll, &QPushButton::clicked, dlg, [ui]() {
        ui->p->resetAll();
        ui->refresh();
    });
    QObject::connect(buttons, &QDialogButtonBox::rejected, dlg, &QDialog::accept);

    // The signal changes under the dialog (the guest switches video mode), and the
    // Sharpness dial's preset position moves with it, so keep the status line live.
    // Stopped when the dialog finishes: the dialog object outlives exec(), and the
    // presenter it reads may not.
    auto *tick = new QTimer(dlg);
    QObject::connect(tick, &QTimer::timeout, dlg, [ui]() {
        ui->status->setText(QString::fromStdString(ui->p->status()));
    });
    QObject::connect(dlg, &QDialog::finished, tick, &QTimer::stop);
    tick->start(500);

    ui->refresh();
    return dlg;
#else
    (void) parent;
    return nullptr;
#endif
}
