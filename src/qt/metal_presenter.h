/*
 * 86Box    Metal presentation core (Apple only).
 *
 *          Shared, UI-framework-agnostic Metal code: owns an MTLDevice, a
 *          CAMetalLayer, a 2048-wide source texture matching 86Box's blit
 *          buffer, and a tiny pipeline that scales the source into the layer's
 *          drawable. The Qt renderer (qt_metalrenderer) is a thin QWindow shell
 *          around this; a standalone test drives the same object. All
 *          Objective-C / Metal lives in metal_presenter.mm so this header stays
 *          pure C++ and is safely includable from plain .cpp translation units.
 *
 *          STUB: scales/stretches the framebuffer straight to the drawable.
 *          The CRTEngine bridge (crt_bridge.h) slots in at the marked seam in
 *          metal_presenter.mm, between upload and present.
 */
#ifndef QT_METAL_PRESENTER_H
#define QT_METAL_PRESENTER_H

#include <cstdint>

class MetalPresenter {
public:
    MetalPresenter();
    ~MetalPresenter();

    MetalPresenter(const MetalPresenter &)            = delete;
    MetalPresenter &operator=(const MetalPresenter &) = delete;

    /* Bring up Metal against an existing CAMetalLayer* (passed as void*).
       Returns false if no Metal device or pipeline could be built. */
    bool init(void *caMetalLayer);
    bool valid() const;

    /* Turn on the CRTEngine phosphor simulation: present() will route the
       framebuffer through the engine instead of straight to screen. Loads the
       given preset (e.g. "VGA monitor") at the initial emulated resolution.
       No-op (returns false) in stub builds without USE_CRTENGINE. */
    bool enableCRT(const char *presetName, int contentW, int contentH);
    bool crtEnabled() const;

    /* Tell the engine the emulated resolution changed (86Box mode switch). */
    void setContentSize(int contentW, int contentH);

    /* The EMULATED CARD's true vertical refresh (Hz), from its CRTC — the rate the
       simulated tube locks to. Pushed with the resolution on a mode change.
       0 = the active card doesn't report timings; the bridge then falls back. */
    void setSignalRefresh(float hz);

    /* HOST display refresh (Hz) for correct field cadence — the physical panel, not
       the emulated card. Different concept from setSignalRefresh. */
    void setDisplayRefresh(float hz);

    /* Detect host-display capabilities (EDR/HDR headroom, refresh, scale) from an
       NSScreen* (or NULL for the main screen), push them into the engine, and put
       the CAMetalLayer into EDR (rgba16Float) mode when the display supports it.
       Call at init and on screen changes. No-op without USE_CRTENGINE. */
    void updateDisplay(void *nsScreen);

    /* Live monitor adjustments (for the renderer options UI). No-op in stub. */
    void setBrightness(float v);
    void setContrast(float v);
    void setPhosphorPattern(int pattern);   /* 0=triode 1=stripe 2=shadow 3=slot */
    void setSharpness(float v);             /* 0=soft .. 1=sharp */
    void setEdgeFocus(float v);
    void setBloom(float v);
    void setConvergence(float v);
    void setHJitter(float v);
    void setVJitter(float v);
    void setShotNoise(float v);
    void setSignalNoise(float v);
    void setHBandwidth(float v);            /* RC rolloff β 0.2..1.0 (lower = sharper) */
    void setHFocus(float v);                /* optical H blur σ 0..3 source px */
    void setBeamSegment(float v);           /* beam temporal resolution 0..1 (1 = whole line, <1 = segmented dot) */
    void setShutter(float v);               /* observer integration 0..1 (1 = fused eye, <1 = camera shutter) */
    void setMaskScale(float v);             /* RGB mask 1x/2x/3x (multiplier of finest) */
    void setPeakHighlights(float v);        /* tube peak headroom 1.0 (SDR look) .. 3.0, capped by live panel headroom */
    void setPreset(int idx);                /* CRT preset by index (see kCrtPresetNames) */

    /* Persistence (NSUserDefaults). loadSettings() applies any saved user
       adjustments over the preset — call once after enableCRT. persistedValue()
       lets the options dialog initialize its controls to the saved state. */
    void  loadSettings();
    float persistedValue(const char *key, float fallback) const;

    /* Set the layer's contentsScale (backing scale factor, e.g. 2.0 on Retina).
       MUST match drawableSize / bounds or Core Animation resamples the whole
       layer (moiré on fine detail). Call before resizeDrawable. */
    void setContentsScale(double scale);

    /* Tell the layer how big its drawable should be (device pixels). */
    void resizeDrawable(int width, int height);

    /* Copy a sub-rect of 86Box's BGRA8 blit buffer (row stride bytesPerRow)
       into the source texture at the same coordinates. */
    void upload(const uint8_t *buf, int x, int y, int w, int h, int bytesPerRow);

    /* Scale source rect (srcX,srcY,srcW,srcH) into the layer's next drawable
       and present it. No-op if no drawable is available. */
    void present(int srcX, int srcY, int srcW, int srcH);

    /* Test/offscreen hook: render the source rect into a caller-owned
       id<MTLTexture> (passed as void*) instead of the layer. Returns false on
       failure. Lets the presentation path be verified headless. */
    bool renderToTexture(void *mtlTexture, int srcX, int srcY, int srcW, int srcH);

    /* Expose the device so a host (or test) can create matching textures. */
    void *device() const; /* returns id<MTLDevice> as void* */

    /* Opaque implementation; defined only in metal_presenter.mm. Public so the
       file-local draw helper there can name it. */
    struct Impl;

private:
    Impl *impl;
};

#endif /* QT_METAL_PRESENTER_H */
