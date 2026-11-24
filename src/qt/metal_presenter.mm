/*
 * 86Box    Metal presentation core (Apple only) — implementation.
 *
 *          See metal_presenter.h. All Objective-C / Metal is confined here.
 */
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <CoreFoundation/CoreFoundation.h>

#include "metal_presenter.h"

#include <cstdio>
#include <cmath>
#include <string>

#ifdef USE_CRTENGINE
#    include "crt_bridge.h"
static NSString *savedPresetName();   // the user's last preset choice; defined with the options code
#endif

/* 86Box hands every renderer a fixed-stride buffer; the source texture matches. */
static const int kSrcDim = 2048;

static const char *kShaderSrc = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float4 texRect; float4 posRect; }; // (u0,v0,u1,v1) (l,t,r,b NDC)
struct VOut     { float4 pos [[position]]; float2 uv; };

vertex VOut v_main(uint vid [[vertex_id]],
                   constant Uniforms &u [[buffer(0)]])
{
    // Triangle strip, 4 corners: (0,0) (1,0) (0,1) (1,1).
    float2 corner = float2(float(vid & 1u), float((vid >> 1) & 1u));
    VOut o;
    o.pos = float4(mix(u.posRect.x, u.posRect.z, corner.x),
                   mix(u.posRect.y, u.posRect.w, corner.y), 0.0, 1.0);
    o.uv  = mix(u.texRect.xy, u.texRect.zw, corner);
    return o;
}

fragment float4 f_main(VOut in [[stage_in]],
                       texture2d<float> tex [[texture(0)]],
                       sampler s [[sampler(0)]])
{
    // Derivative-aware Gaussian downsample. The source footprint of one output
    // pixel (fwidth of the texcoord, in texels) tells us the minification ratio;
    // we integrate the source over that footprint with a Gaussian so the fine
    // scanline/stripe pattern resamples cleanly instead of aliasing into bunched
    // bands. When magnifying (footprint <= 1) we sample sharply — no blur.
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 fp = fwidth(in.uv) * texSize;
    if (max(fp.x, fp.y) <= 1.0)
        return float4(tex.sample(s, in.uv).rgb, 1.0);

    // σ ≈ 0.85·footprint gives FWHM ≈ one output-pixel period (2·footprint
    // texels), i.e. a true low-pass at the display's Nyquist. This removes the
    // aliasing harmonics of the sharp scanlines/stripes — the cause of the broad
    // moiré beat — while keeping the scanline fundamental itself. Too narrow (0.5)
    // leaves the harmonics and they beat; this is the right amount.
    float2 sigma = max(fp * 0.85, float2(0.5));
    float3 sum = float3(0.0);
    float  wsum = 0.0;
    for (int j = -3; j <= 3; ++j) {
        for (int i = -3; i <= 3; ++i) {
            float2 d = float2(i, j) * sigma;             // sample out to ±3σ
            float  w = exp(-0.5 * float(i * i + j * j));  // Gaussian weight (σ units)
            sum  += tex.sample(s, in.uv + d / texSize).rgb * w;
            wsum += w;
        }
    }
    return float4(sum / wsum, 1.0);   // force opaque
}
)METAL";

struct MetalPresenter::Impl {
    id<MTLDevice>              device      = nil;
    id<MTLCommandQueue>        queue       = nil;
    id<MTLLibrary>             library     = nil;   // kept so the pipeline can be
                                                    // rebuilt on EDR format change
    id<MTLRenderPipelineState> pipeline    = nil;
    id<MTLSamplerState>        sampler     = nil;
    id<MTLSamplerState>        mipSampler  = nil;   // trilinear, for minifying
                                                    // the high-res CRT output
    id<MTLTexture>             mipTex      = nil;   // mipmapped copy of the CRT
                                                    // output, for clean downscale
    id<MTLTexture>             source      = nil;   // kSrcDim x kSrcDim BGRA8
    CAMetalLayer             *layer        = nil;   // not owned
    MTLPixelFormat            layerFormat  = MTLPixelFormatBGRA8Unorm;

#ifdef USE_CRTENGINE
    CRTBridgeRef   crt        = nullptr;
    bool           crtOn      = false;
    int            cw         = 0;       // current content (emulated) resolution
    int            ch         = 0;
    float          signalHz   = 0.0f;    // emulated card's true refresh (0 = unreported)
    float          sentHz     = -1.0f;   // last refresh pushed to the bridge
    bool           presentFailing = false;   // crt_bridge_present is failing: raw feed on screen
    int            edrState   = -1;      // layer EDR setup last applied: -1 none, 0 SDR, 1 EDR
    id<MTLTexture> content    = nil;     // the (upscaled) frame fed to the engine
    CFAbsoluteTime startTime  = 0;       // phosphor/beam clock origin
#endif
};

MetalPresenter::MetalPresenter()  : impl(new Impl) {}
MetalPresenter::~MetalPresenter()
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        crt_bridge_destroy(impl->crt);
#endif
    delete impl;
}

/* (Re)build the present pipeline for the current impl->layerFormat. Called at
   init and whenever the layer switches between BGRA8 (SDR) and RGBA16Float (EDR). */
static bool
buildPipeline(MetalPresenter::Impl *impl)
{
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction                  = [impl->library newFunctionWithName:@"v_main"];
    pd.fragmentFunction                = [impl->library newFunctionWithName:@"f_main"];
    pd.colorAttachments[0].pixelFormat = impl->layerFormat;
    NSError *err = nil;
    impl->pipeline = [impl->device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (impl->pipeline == nil) {
        fprintf(stderr, "[MetalPresenter] pipeline failed: %s\n",
                err ? err.localizedDescription.UTF8String : "?");
        return false;
    }
    return true;
}

bool
MetalPresenter::valid() const
{
    return impl->device != nil && impl->pipeline != nil;
}

void *
MetalPresenter::device() const
{
    return (__bridge void *) impl->device;
}

bool
MetalPresenter::init(void *caMetalLayer)
{
    impl->layer  = (__bridge CAMetalLayer *) caMetalLayer;
    impl->device = MTLCreateSystemDefaultDevice();
    if (impl->device == nil) {
        fprintf(stderr, "[MetalPresenter] no Metal device\n");
        return false;
    }
    if (impl->layer != nil) {
        impl->layer.device      = impl->device;
        impl->layer.pixelFormat = impl->layerFormat;
        impl->layer.framebufferOnly = YES;
    }
    impl->queue = [impl->device newCommandQueue];

    NSError *err = nil;
    impl->library =
        [impl->device newLibraryWithSource:[NSString stringWithUTF8String:kShaderSrc]
                                   options:nil
                                     error:&err];
    if (impl->library == nil) {
        fprintf(stderr, "[MetalPresenter] shader compile failed: %s\n",
                err ? err.localizedDescription.UTF8String : "?");
        return false;
    }
    if (!buildPipeline(impl)) {
        fprintf(stderr, "[MetalPresenter] pipeline build failed\n");
        return false;
    }

    MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
    sd.minFilter = MTLSamplerMinMagFilterLinear;
    sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    impl->sampler = [impl->device newSamplerStateWithDescriptor:sd];

    // Trilinear: averages across mip levels when the high-res phosphor buffer is
    // minified to the window, so the fine scanline/stripe pattern downsamples
    // cleanly instead of aliasing into moiré bands.
    sd.mipFilter = MTLSamplerMipFilterLinear;
    impl->mipSampler = [impl->device newSamplerStateWithDescriptor:sd];

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:kSrcDim
                                                          height:kSrcDim
                                                       mipmapped:NO];
    td.usage       = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    impl->source   = [impl->device newTextureWithDescriptor:td];

    if (valid())
        fprintf(stderr, "[MetalPresenter] init OK — device=%s, layer=%s\n",
                impl->device.name.UTF8String, impl->layer ? "attached" : "none");
    return valid();
}

void
MetalPresenter::setContentsScale(double scale)
{
    // Layer-hosting views don't get contentsScale managed by AppKit, so it stays
    // at the default 1.0 while we hand the layer a Retina-sized drawable — Core
    // Animation then resamples the whole layer to fit its 1x bounds, moiréing the
    // fine CRT detail. Pin it to the real backing scale so drawableSize maps 1:1.
    if (impl->layer && scale > 0.0)
        impl->layer.contentsScale = scale;
}

void
MetalPresenter::resizeDrawable(int width, int height)
{
    if (impl->layer && width > 0 && height > 0)
        impl->layer.drawableSize = CGSizeMake(width, height);
#ifdef USE_CRTENGINE
    if (impl->crt && width > 0 && height > 0)
        crt_bridge_set_drawable_size(impl->crt, width, height);
#endif
}

void
MetalPresenter::upload(const uint8_t *buf, int x, int y, int w, int h, int bytesPerRow)
{
    if (impl->source == nil || buf == nullptr || w <= 0 || h <= 0)
        return;
    if (x < 0 || y < 0 || (x + w) > kSrcDim || (y + h) > kSrcDim)
        return;
    const uint8_t *origin = buf + (size_t) y * bytesPerRow + (size_t) x * 4;
    [impl->source replaceRegion:MTLRegionMake2D(x, y, w, h)
                    mipmapLevel:0
                      withBytes:origin
                    bytesPerRow:bytesPerRow];
}

/* Shared draw: rect of `srcTex` (its own pixel coords) -> a destination NDC rect
   of `target` (l,t,r,b). Normalizes by the source texture's own dimensions so it
   serves both the 2048 stub buffer and an arbitrarily-sized engine output. */
static void
drawInto(MetalPresenter::Impl *impl, id<MTLTexture> target, id<MTLTexture> srcTex,
         int srcX, int srcY, int srcW, int srcH,
         const float posRect[4], id<MTLSamplerState> sampler,
         id<MTLRenderPipelineState> pipeline, id<MTLCommandBuffer> cb)
{
    float tw = (float) srcTex.width, th = (float) srcTex.height;
    struct { float texRect[4]; float posRect[4]; } u = {
        { srcX / tw, srcY / th, (srcX + srcW) / tw, (srcY + srcH) / th },
        { posRect[0], posRect[1], posRect[2], posRect[3] }
    };

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture     = target;
    rp.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pipeline];
    [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
    [enc setFragmentTexture:srcTex atIndex:0];
    [enc setFragmentSamplerState:sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
}


static const float kFullRect[4] = { -1.0f, 1.0f, 1.0f, -1.0f };

/* NDC dest rect that fits an image of aspect `srcW:srcH` into the drawable,
   centered, preserving aspect (pillarbox/letterbox). Scales the source to the
   drawable — used to downsample the high-res engine output into the window. */
static void
aspectFit(int srcW, int srcH, int dstW, int dstH, float out[4])
{
    float srcAspect = (float) srcW / (float) srcH;
    float dstAspect = (float) dstW / (float) dstH;
    float sx = 1.0f, sy = 1.0f;
    if (dstAspect >= srcAspect)      sx = srcAspect / dstAspect;  // wider -> pillarbox
    else                             sy = dstAspect / srcAspect;  // taller -> letterbox
    out[0] = -sx; out[1] = sy; out[2] = sx; out[3] = -sy;         // l, t, r, b (NDC)
}

#ifdef USE_CRTENGINE
/* Signal diagnostics. stderr is invisible when the .app is launched from Finder
   (macOS does not route a GUI app's stdio anywhere readable), so mode changes are
   also appended to ~/Library/Logs/86Box-crt-signal.log. Mode changes are rare, so
   the open/close per line costs nothing. */
static void
logSignal(const char *what, int w, int h, float hz)
{
    fprintf(stderr, "[MetalPresenter] signal -> %dx%d @ %.3f Hz (%s)\n", w, h, hz, what);
    const char *home = getenv("HOME");
    if (home == nullptr)
        return;
    char path[1024];
    snprintf(path, sizeof(path), "%s/Library/Logs/86Box-crt-signal.log", home);
    FILE *f = fopen(path, "a");
    if (f == nullptr)
        return;
    fprintf(f, "signal -> %dx%d @ %.3f Hz (%s)\n", w, h, hz, what);
    fclose(f);
}

/* Run the framebuffer through CRTEngine and present the simulated result.
   Returns false if the CRT path isn't usable this frame (caller falls back). */
static bool
presentCRT(MetalPresenter::Impl *impl, int srcX, int srcY, int srcW, int srcH)
{
    if (!impl->crtOn || impl->crt == nullptr || srcW <= 0 || srcH <= 0)
        return false;

    // Diagnostic: METAL_CRT_PROBE=1 dumps a middle row of the raw feed (the shared
    // 2048 staging texture, straight from 86Box's framebuffer) ONCE, so we can see
    // from real pixel values whether a "flat" fill is actually constant or has
    // per-column variation. Settles feed-vs-render questions without eyeballing.
    if (getenv("METAL_CRT_PROBE") != nullptr) {
        static int probeFrame = 0;
        if ((probeFrame++ % 60) == 0 && impl->source != nil) {   // ~1x/sec, not one-shot
            static uint8_t row[kSrcDim * 4];
            int py = srcY + srcH / 2;
            [impl->source getBytes:row bytesPerRow:(NSUInteger) srcW * 4
                        fromRegion:MTLRegionMake2D(srcX, py, srcW, 1) mipmapLevel:0];
            int rmin = 255, rmax = 0, gmin = 255, gmax = 0, bmin = 255, bmax = 0, transitions = 0;
            uint32_t prev = 0;
            for (int i = 0; i < srcW; i++) {
                uint8_t b = row[i * 4 + 0], g = row[i * 4 + 1], r = row[i * 4 + 2];
                rmin = r < rmin ? r : rmin; rmax = r > rmax ? r : rmax;
                gmin = g < gmin ? g : gmin; gmax = g > gmax ? g : gmax;
                bmin = b < bmin ? b : bmin; bmax = b > bmax ? b : bmax;
                uint32_t px = ((uint32_t) r << 16) | ((uint32_t) g << 8) | b;
                if (i > 0 && px != prev) transitions++;
                prev = px;
            }
            fprintf(stderr, "[MetalPresenter] PROBE row y=%d w=%d: R[%d..%d] G[%d..%d] "
                            "B[%d..%d] color-transitions=%d\n",
                    py, srcW, rmin, rmax, gmin, gmax, bmin, bmax, transitions);
        }
    }

    // Feed the engine the native frame — no host resample. The VGA encoder's output
    // scanline count is pinned to the mode (CRTBridge applyPresetInternal), so its
    // output resolution matches the native frame and it hits its 1:1 passthrough
    // path; the engine's beam + downscale own all resampling.
    if (srcW != impl->cw || srcH != impl->ch || impl->content == nil) {
        logSignal("mode change", srcW, srcH, impl->signalHz);
        impl->cw     = srcW;
        impl->ch     = srcH;
        impl->sentHz = impl->signalHz;
        // The whole cable in one push: resolution + the card's true refresh.
        crt_bridge_set_signal(impl->crt, srcW, srcH, impl->signalHz);
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:srcW height:srcH mipmapped:NO];
        td.usage       = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        impl->content  = [impl->device newTextureWithDescriptor:td];
    } else if (fabsf(impl->signalHz - impl->sentHz) > 0.05f) {
        // Same resolution, different rate — e.g. 640x480 60 Hz -> 72 Hz. Still a mode
        // change as far as the tube is concerned: it has to re-lock to the new sync.
        // Tolerance, not equality: the CRTC's derived rate jitters in the last decimal
        // and a real tube would not re-lock over a millihertz.
        logSignal("refresh change", srcW, srcH, impl->signalHz);
        impl->sentHz = impl->signalHz;
        crt_bridge_set_signal(impl->crt, srcW, srcH, impl->signalHz);
    }

    id<MTLCommandBuffer> cb = [impl->queue commandBuffer];

    // Lift the active frame out of the 2048 staging buffer into the exact content-
    // sized texture the engine treats as the screen.
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:impl->source sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(srcX, srcY, 0)
               sourceSize:MTLSizeMake(srcW, srcH, 1)
                toTexture:impl->content destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    // Diagnostic: METAL_CRT_BYPASS=1 presents the raw 86Box feed (the exact content
    // texture, no CRT) scaled to the window. Lets us tell whether an artifact lives
    // in 86Box's framebuffer (e.g. a dithered "flat" fill) or is introduced by the
    // engine/present. Static so getenv() runs once.
    static const bool bypassCRT = (getenv("METAL_CRT_BYPASS") != nullptr);
    if (bypassCRT) {
        id<CAMetalDrawable> d = [impl->layer nextDrawable];
        if (d == nil) { [cb commit]; return true; }
        float bp[4];
        aspectFit(srcW, srcH, (int) d.texture.width, (int) d.texture.height, bp);
        drawInto(impl, d.texture, impl->content, 0, 0, srcW, srcH, bp,
                 impl->sampler, impl->pipeline, cb);
        [cb presentDrawable:d];
        [cb commit];
        return true;
    }

    // Hand the frame to CRTEngine and let IT put the picture on our drawable — sim,
    // band-limited downscale, transfer encoding and aspect-fit viewport, all engine
    // policy (CRTEngine's DisplayCompositor).
    //
    // The host used to do the last step itself (crt_bridge_render + f_main + aspectFit).
    // That was wrong on two counts, and both were visible: f_main point-sampled whenever
    // it was magnifying (footprint <= 1), which aliases a 1px mask and the scanline comb —
    // the artifact showed in triode too, because the comb aliases with no mask present.
    // And it wrote the engine's LINEAR output straight into whatever the layer was: into
    // an 8-bit DisplayP3 layer that reads dark, because the display pipeline applies its
    // EOTF expecting an encoded signal.
    //
    // `sdrEncoded` = "our drawable is 8-bit gamma-encoded". It tracks the layer format we
    // chose in updateDisplay(): bgra8Unorm + DisplayP3 (SDR) vs rgba16Float + extended
    // linear (EDR). The engine encodes to match.
    const bool sdrEncoded = (impl->layerFormat != MTLPixelFormatRGBA16Float);

    id<CAMetalDrawable> drawable = [impl->layer nextDrawable];
    if (drawable == nil) { [cb commit]; return true; }   // skip frame, not a fallback

    float t = (float) (CFAbsoluteTimeGetCurrent() - impl->startTime);
    if (!crt_bridge_present(impl->crt, (__bridge void *) impl->content, t,
                            (__bridge void *) drawable.texture, (__bridge void *) cb,
                            sdrEncoded)) {
        // The caller now draws the RAW feed instead. That fallback is silent on screen —
        // a picture appears, it is simply not the tube's, and every CRT control goes
        // dead — so it must not be silent here too. Say so once per run of failures.
        if (!impl->presentFailing) {
            impl->presentFailing = true;
            logSignal("CRT PRESENT FAILED - showing the RAW feed, CRT controls are inert",
                      srcW, srcH, impl->signalHz);
        }
        [cb commit];
        return false;
    }
    if (impl->presentFailing) {
        impl->presentFailing = false;
        logSignal("CRT present recovered", srcW, srcH, impl->signalHz);
    }
    [cb presentDrawable:drawable];
    [cb commit];
    return true;
}
#endif

void
MetalPresenter::present(int srcX, int srcY, int srcW, int srcH)
{
    if (!valid() || impl->layer == nil)
        return;

#ifdef USE_CRTENGINE
    if (presentCRT(impl, srcX, srcY, srcW, srcH))
        return;
#endif

    // Stub path: present the staging buffer straight.
    id<CAMetalDrawable> drawable = [impl->layer nextDrawable];
    if (drawable == nil)
        return;

    id<MTLCommandBuffer> cb = [impl->queue commandBuffer];
    drawInto(impl, drawable.texture, impl->source, srcX, srcY, srcW, srcH, kFullRect,
             impl->sampler, impl->pipeline, cb);
    [cb presentDrawable:drawable];
    [cb commit];
}

bool
MetalPresenter::renderToTexture(void *mtlTexture, int srcX, int srcY, int srcW, int srcH)
{
    if (!valid() || mtlTexture == nullptr)
        return false;
    id<MTLTexture> target = (__bridge id<MTLTexture>) mtlTexture;
    id<MTLCommandBuffer> cb = [impl->queue commandBuffer];
    drawInto(impl, target, impl->source, srcX, srcY, srcW, srcH, kFullRect,
             impl->sampler, impl->pipeline, cb);
    [cb commit];
    [cb waitUntilCompleted];
    return true;
}

bool
MetalPresenter::crtEnabled() const
{
#ifdef USE_CRTENGINE
    return impl->crtOn;
#else
    return false;
#endif
}

bool
MetalPresenter::enableCRT(const char *presetName, int contentW, int contentH)
{
#ifdef USE_CRTENGINE
    if (!valid())
        return false;

    CGSize ds   = impl->layer.drawableSize;
    int    dw   = ds.width  > 0 ? (int) ds.width  : 1280;
    int    dh   = ds.height > 0 ? (int) ds.height : 960;

    // Shaders + presets load from CRTEngine's own resource bundle (Bundle.module),
    // which the build copies into the .app's Resources — so CRTEngine is unmodified.
    impl->crt = crt_bridge_create((__bridge void *) impl->device, dw, dh);
    if (impl->crt == nullptr) {
        fprintf(stderr, "[MetalPresenter] enableCRT: bridge create failed "
                        "(CRTEngine resource bundle / metallib missing?)\n");
        return false;
    }
    // The dial list is declared twice — CRTDial here, `Dial` in CRTBridge.swift — and
    // nothing in the toolchain ties a C enum to a Swift one. If they drift, every dial
    // after the drift point drives its neighbour, so say so loudly rather than let a
    // slider quietly move the wrong thing.
    if (crt_bridge_dial_count() != CRT_DIAL_COUNT)
        fprintf(stderr, "[MetalPresenter] WARNING: crt_bridge.h declares %d dials, the bridge "
                        "implements %d — rebuild with crtbridge/build.sh\n",
                (int) CRT_DIAL_COUNT, crt_bridge_dial_count());

    // The tube: the one the user last chose, else the caller's default.
    NSString   *saved  = savedPresetName();
    const char *chosen = saved ? saved.UTF8String : presetName;
    if (!crt_bridge_set_preset(impl->crt, chosen)
        && (chosen == presetName || !crt_bridge_set_preset(impl->crt, presetName))) {
        fprintf(stderr, "[MetalPresenter] enableCRT: preset '%s' failed\n", presetName);
        crt_bridge_destroy(impl->crt);
        impl->crt = nullptr;
        return false;
    }
    impl->cw        = contentW;
    impl->ch        = contentH;
    impl->content   = nil;          // built lazily in presentCRT at the real size
    impl->startTime = CFAbsoluteTimeGetCurrent();
    impl->crtOn     = true;
    loadSettings();   // the user's dial positions, over the preset's
    fprintf(stderr, "[MetalPresenter] CRT enabled — preset '%s', drawable %dx%d\n",
            crt_bridge_preset_name(crt_bridge_current_preset(impl->crt)), dw, dh);
    return true;
#else
    (void) presetName; (void) contentW; (void) contentH;
    return false;
#endif
}

void
MetalPresenter::setSignalRefresh(float hz)
{
#ifdef USE_CRTENGINE
    // Recorded now, pushed with the next frame's signal (presentCRT), so resolution
    // and refresh always reach the engine together.
    impl->signalHz = hz;
#else
    (void) hz;
#endif
}

void
MetalPresenter::setDisplayRefresh(float hz)
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        crt_bridge_set_display_refresh(impl->crt, hz);
#else
    (void) hz;
#endif
}

/* ---- CRT options: apply to the engine AND persist (NSUserDefaults) ----------------

   One table, indexed by CRTDial, gives each dial its defaults key. A dial is persisted
   only once the user has moved it; an absent key means "the preset's position", so a
   preset keeps its own look for everything the user has left alone, and Reset is just
   removing the key.

   A PERSISTED KEY OUTLIVES THE CONTROL THAT WROTE IT. Two sliders (crt.scansmooth,
   crt.patsmooth) were once removed from the dialog while their loader stayed: the last
   values they had held were then re-applied on every launch with no UI left to undo
   them, and it cost a measured 8x scanline beat. Loading is now driven by this table and
   nothing else, so a dial that leaves the table stops being loaded in the same edit —
   but a key retired here is still on disk, and must not be given a new meaning. */
#ifdef USE_CRTENGINE
static const char *const kDialKeys[CRT_DIAL_COUNT] = {
    /* CRT_DIAL_BRIGHTNESS      */ "crt.brightness",
    /* CRT_DIAL_CONTRAST        */ "crt.contrast",
    /* CRT_DIAL_SATURATION      */ "crt.saturation",
    /* CRT_DIAL_PEAK_HIGHLIGHTS */ "crt.peaks",
    /* CRT_DIAL_PATTERN_SCALE   */ "crt.maskscale",   // same unit it always wrote: px per triad
    /* CRT_DIAL_PATTERN_FOCUS   */ "crt.patternfocus",
    /* CRT_DIAL_CURVATURE       */ "crt.curvature",
    /* CRT_DIAL_HALATION        */ "crt.halation",
    /* CRT_DIAL_SCATTER         */ "crt.scatter",
    /* CRT_DIAL_OVERSCAN        */ "crt.overscan",
    /* CRT_DIAL_VIGNETTE        */ "crt.vignette",
    /* CRT_DIAL_SHARPNESS       */ "crt.sharpness",
    /* CRT_DIAL_H_BANDWIDTH     */ "crt.hbandwidth",
    /* CRT_DIAL_H_FOCUS         */ "crt.hfocus",
    /* CRT_DIAL_SHUTTER         */ "crt.shutter",
    /* CRT_DIAL_EDGE_FOCUS      */ "crt.edge",
    /* CRT_DIAL_BLOOM           */ "crt.bloom",
    /* CRT_DIAL_CONVERGENCE     */ "crt.convergence",
    /* CRT_DIAL_H_JITTER        */ "crt.hjitter",
    /* CRT_DIAL_V_JITTER        */ "crt.vjitter",
    /* CRT_DIAL_SHOT_NOISE      */ "crt.shotnoise",
    /* CRT_DIAL_SIGNAL_NOISE    */ "crt.signalnoise",
};
static NSString *const kPatternKey    = @"crt.pattern";
static NSString *const kPresetNameKey = @"crt.presetName";
static NSString *const kLegacyPresetIndexKey = @"crt.preset";

static inline NSString *dialKey(int dial) { return [NSString stringWithUTF8String:kDialKeys[dial]]; }
static inline bool      dialValid(int dial) { return dial >= 0 && dial < CRT_DIAL_COUNT; }

/* The preset the user last chose, by NAME. The choice used to be stored as an index
   into a table of names kept in this file; the engine then renamed one ("White CRT
   monitor" -> "B&W CRT monitor") and that entry silently stopped resolving. A name
   survives the engine reordering or adding presets; an old index is translated once
   through the table as it stood when the index was written. */
static NSString *
savedPresetName()
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (NSString *name = [d stringForKey:kPresetNameKey])
        return name;
    if ([d objectForKey:kLegacyPresetIndexKey] != nil) {
        static NSString *const legacy[] = {
            @"Green CRT monitor", @"Amber CRT monitor", @"B&W CRT monitor",
            @"NTSC black and white", @"NTSC color", @"VGA monitor",
        };
        long i = lroundf([d floatForKey:kLegacyPresetIndexKey]);
        if (i >= 0 && i < 6)
            return legacy[i];
    }
    return nil;
}
#endif

int
MetalPresenter::presetCount() const
{
#ifdef USE_CRTENGINE
    return crt_bridge_preset_count();
#else
    return 0;
#endif
}

const char *
MetalPresenter::presetName(int index) const
{
#ifdef USE_CRTENGINE
    return crt_bridge_preset_name(index);
#else
    (void) index;
    return nullptr;
#endif
}

int
MetalPresenter::currentPreset() const
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        return crt_bridge_current_preset(impl->crt);
#endif
    return -1;
}

void
MetalPresenter::setPreset(int index)
{
#ifdef USE_CRTENGINE
    const char *name = crt_bridge_preset_name(index);
    if (impl->crt == nullptr || name == nullptr || !crt_bridge_set_preset(impl->crt, name))
        return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:[NSString stringWithUTF8String:name] forKey:kPresetNameKey];
    [d removeObjectForKey:kLegacyPresetIndexKey];
#else
    (void) index;
#endif
}

bool
MetalPresenter::isColor() const
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        return crt_bridge_is_color(impl->crt);
#endif
    return false;
}

int
MetalPresenter::phosphorPattern() const
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        return crt_bridge_get_phosphor_pattern(impl->crt);
#endif
    return 0;
}

void
MetalPresenter::setPhosphorPattern(int pattern)
{
#ifdef USE_CRTENGINE
    if (impl->crt == nullptr || pattern < 0 || pattern > 3)
        return;
    crt_bridge_set_phosphor_pattern(impl->crt, pattern);
    [[NSUserDefaults standardUserDefaults] setInteger:pattern forKey:kPatternKey];
#else
    (void) pattern;
#endif
}

bool
MetalPresenter::dialRange(int dial, float *lo, float *hi) const
{
#ifdef USE_CRTENGINE
    return crt_bridge_dial_range(dial, lo, hi);
#else
    (void) dial; (void) lo; (void) hi;
    return false;
#endif
}

float
MetalPresenter::dial(int dial) const
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        return crt_bridge_get_dial(impl->crt, dial);
#endif
    (void) dial;
    return 0.0f;
}

float
MetalPresenter::dialDefault(int dial) const
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        return crt_bridge_dial_default(impl->crt, dial);
#endif
    (void) dial;
    return 0.0f;
}

bool
MetalPresenter::dialIsSet(int dial) const
{
#ifdef USE_CRTENGINE
    if (impl->crt)
        return crt_bridge_dial_is_set(impl->crt, dial);
#endif
    (void) dial;
    return false;
}

void
MetalPresenter::setDial(int dial, float v)
{
#ifdef USE_CRTENGINE
    if (impl->crt == nullptr || !dialValid(dial))
        return;
    crt_bridge_set_dial(impl->crt, dial, v);
    // Persist what the bridge kept (it clamps to the dial's range), not what was asked.
    [[NSUserDefaults standardUserDefaults] setFloat:crt_bridge_get_dial(impl->crt, dial)
                                             forKey:dialKey(dial)];
#else
    (void) dial; (void) v;
#endif
}

void
MetalPresenter::resetDial(int dial)
{
#ifdef USE_CRTENGINE
    if (impl->crt == nullptr || !dialValid(dial))
        return;
    crt_bridge_reset_dial(impl->crt, dial);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:dialKey(dial)];
#else
    (void) dial;
#endif
}

void
MetalPresenter::resetAll()
{
#ifdef USE_CRTENGINE
    if (impl->crt == nullptr)
        return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (int dial = 0; dial < CRT_DIAL_COUNT; dial++) {
        crt_bridge_reset_dial(impl->crt, dial);
        [d removeObjectForKey:dialKey(dial)];
    }
    crt_bridge_set_phosphor_pattern(impl->crt, -1);   // the preset's own
    [d removeObjectForKey:kPatternKey];
#endif
}

std::string
MetalPresenter::status() const
{
#ifdef USE_CRTENGINE
    if (impl->crt) {
        char buf[512];
        crt_bridge_describe(impl->crt, buf, (int) sizeof(buf));
        return std::string(buf);
    }
#endif
    return std::string();
}

void
MetalPresenter::loadSettings()
{
#ifdef USE_CRTENGINE
    if (impl->crt == nullptr)
        return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // Only what the user actually moved; everything else stays on the preset.
    if ([d objectForKey:kPatternKey] != nil) {
        long p = lroundf([d floatForKey:kPatternKey]);
        if (p >= 0 && p <= 3)
            crt_bridge_set_phosphor_pattern(impl->crt, (int) p);
    }
    for (int dial = 0; dial < CRT_DIAL_COUNT; dial++) {
        NSString *key = dialKey(dial);
        if ([d objectForKey:key] != nil)
            crt_bridge_set_dial(impl->crt, dial, [d floatForKey:key]);
    }
#endif
}

void
MetalPresenter::updateDisplay(void *nsScreen)
{
#ifdef USE_CRTENGINE
    if (!impl->crt)
        return;
    crt_bridge_update_display(impl->crt, nsScreen);

    // Put the layer in EDR mode whenever the display has ANY headroom above SDR, so the
    // engine's >1.0 phosphor/mask brightness has somewhere real to go instead of being
    // soft-clipped into the SDR range. (Was 1.05; a panel reporting even a little headroom
    // is better served by the float/linear path than by encoding down to 8 bits.)
    bool edr = crt_bridge_edr_headroom(impl->crt) > 1.0f;

    // Touch the layer only when the answer CHANGES. This is called for every display
    // report, and macOS posts a screen-parameters notification for every twitch of EDR
    // headroom — about a dozen a second while EDR settles. Re-writing the layer's format,
    // EDR flag and colour space on each one was, at best, churn (and it leaked a
    // CGColorSpace per call: Create without Release).
    if (impl->edrState == (edr ? 1 : 0))
        return;
    impl->edrState = edr ? 1 : 0;

    MTLPixelFormat desired = edr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    if (desired != impl->layerFormat) {
        impl->layerFormat = desired;
        if (!buildPipeline(impl))      // rebuild for the new attachment format
            return;
        impl->layer.pixelFormat = desired;
    }
    impl->layer.wantsExtendedDynamicRangeContent = edr;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(
        edr ? kCGColorSpaceExtendedLinearDisplayP3 : kCGColorSpaceDisplayP3);
    impl->layer.colorspace = cs;       // the layer retains it
    CGColorSpaceRelease(cs);
    fprintf(stderr, "[MetalPresenter] display updated — EDR %s (headroom %.2f)\n",
            edr ? "ON" : "off", crt_bridge_edr_headroom(impl->crt));
#else
    (void) nsScreen;
#endif
}
