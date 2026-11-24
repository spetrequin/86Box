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
#include <string>

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
       framebuffer through the engine instead of straight to screen. Comes up on the
       preset the user last chose, or `presetName` (e.g. "VGA monitor") if none, with
       their saved dial positions applied. contentW/H seed the emulated resolution; the
       real signal is pushed with the first frame.
       No-op (returns false) in stub builds without USE_CRTENGINE. */
    bool enableCRT(const char *presetName, int contentW, int contentH);
    bool crtEnabled() const;

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

    /* ---- CRT options (for the renderer options dialog) ----------------------------
       Everything the dialog shows comes from the engine through these: the preset
       list, each dial's range, where the live preset starts it and where it is now.
       The dialog therefore holds no ranges, no defaults and no preset names of its
       own. Setters apply to the live engine AND persist (NSUserDefaults); a dial is
       persisted only once the user moves it, and resetting forgets it again.
       `dial` is a CRTDial from crt_bridge.h. All inert in stub builds. */
    int         presetCount() const;
    const char *presetName(int index) const;   /* the engine's name; NULL past the end */
    int         currentPreset() const;         /* index, or -1 */
    void        setPreset(int index);
    bool        isColor() const;               /* the live tube has a phosphor pattern */

    int  phosphorPattern() const;              /* 0=triode 1=stripe 2=shadow 3=slot, as drawn */
    void setPhosphorPattern(int pattern);

    bool  dialRange(int dial, float *lo, float *hi) const;
    float dial(int dial) const;                /* the user's position, or the preset's */
    float dialDefault(int dial) const;         /* where the live preset starts it */
    bool  dialIsSet(int dial) const;           /* moved off the preset by the user */
    void  setDial(int dial, float v);
    void  resetDial(int dial);                 /* back to the preset */
    void  resetAll();                          /* every dial and the pattern */

    /* One line: the signal the tube is locked to, what the engine laid out for it,
       and the panel's headroom. Empty in stub builds. */
    std::string status() const;

    /* Apply the persisted user adjustments over the preset. enableCRT calls it. */
    void loadSettings();

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
