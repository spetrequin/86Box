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

#ifdef USE_CRTENGINE
#    include "crt_bridge.h"
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
        [cb commit];
        return false;
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
    if (!crt_bridge_apply_preset(impl->crt, presetName, contentW, contentH)) {
        fprintf(stderr, "[MetalPresenter] enableCRT: preset '%s' failed\n", presetName);
        crt_bridge_destroy(impl->crt);
        impl->crt = nullptr;
        return false;
    }
    crt_bridge_set_drawable_size(impl->crt, dw, dh);
    impl->cw        = contentW;
    impl->ch        = contentH;
    impl->content   = nil;          // built lazily in presentCRT at the real size
    impl->startTime = CFAbsoluteTimeGetCurrent();
    impl->crtOn     = true;
    loadSettings();   // re-apply persisted user adjustments over the preset
    fprintf(stderr, "[MetalPresenter] CRT enabled — preset '%s', drawable %dx%d\n",
            presetName, dw, dh);
    return true;
#else
    (void) presetName; (void) contentW; (void) contentH;
    return false;
#endif
}

void
MetalPresenter::setContentSize(int contentW, int contentH)
{
#ifdef USE_CRTENGINE
    if (impl->crt && (contentW != impl->cw || contentH != impl->ch)) {
        impl->cw = contentW;
        impl->ch = contentH;
        crt_bridge_set_content_size(impl->crt, contentW, contentH);
        impl->content = nil;        // force rebuild at the new size
    }
#else
    (void) contentW; (void) contentH;
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

#ifdef USE_CRTENGINE
static inline void crtPersist(const char *key, float v) {
    [[NSUserDefaults standardUserDefaults] setFloat:v
        forKey:[NSString stringWithUTF8String:key]];
}
// CRT preset names, index-aligned with the options dialog's preset combo. Order
// must match. Index 5 ("VGA monitor") is the default 86Box enables.
static const char *kCrtPresetNames[] = {
    "Green CRT monitor", "Amber CRT monitor", "White CRT monitor",
    "NTSC black and white", "NTSC color", "VGA monitor",
};
// Apply to the engine (if live) AND persist under `key` for next launch.
#  define CRT_SET(call, key, v) do { if (impl->crt) call; crtPersist(key, (float)(v)); } while (0)
#else
#  define CRT_SET(call, key, v) do { (void)(v); } while (0)
#endif

void MetalPresenter::setBrightness(float v)     { CRT_SET(crt_bridge_set_brightness(impl->crt, v),       "crt.brightness", v); }
void MetalPresenter::setContrast(float v)       { CRT_SET(crt_bridge_set_contrast(impl->crt, v),         "crt.contrast", v); }
void MetalPresenter::setPhosphorPattern(int p)  { CRT_SET(crt_bridge_set_phosphor_pattern(impl->crt, p), "crt.pattern", p); }
void MetalPresenter::setSharpness(float v)      { CRT_SET(crt_bridge_set_sharpness(impl->crt, v),        "crt.sharpness", v); }
void MetalPresenter::setEdgeFocus(float v)      { CRT_SET(crt_bridge_set_edge_focus(impl->crt, v),       "crt.edge", v); }
void MetalPresenter::setBloom(float v)          { CRT_SET(crt_bridge_set_bloom(impl->crt, v),            "crt.bloom", v); }
void MetalPresenter::setConvergence(float v)    { CRT_SET(crt_bridge_set_convergence(impl->crt, v),      "crt.convergence", v); }
void MetalPresenter::setHJitter(float v)        { CRT_SET(crt_bridge_set_h_jitter(impl->crt, v),         "crt.hjitter", v); }
void MetalPresenter::setVJitter(float v)        { CRT_SET(crt_bridge_set_v_jitter(impl->crt, v),         "crt.vjitter", v); }
void MetalPresenter::setShotNoise(float v)      { CRT_SET(crt_bridge_set_shot_noise(impl->crt, v),       "crt.shotnoise", v); }
void MetalPresenter::setSignalNoise(float v)    { CRT_SET(crt_bridge_set_signal_noise(impl->crt, v),     "crt.signalnoise", v); }
void MetalPresenter::setHBandwidth(float v)     { CRT_SET(crt_bridge_set_h_bandwidth(impl->crt, v),      "crt.hbandwidth", v); }
void MetalPresenter::setHFocus(float v)         { CRT_SET(crt_bridge_set_h_focus(impl->crt, v),          "crt.hfocus", v); }
void MetalPresenter::setBeamSegment(float v)    { CRT_SET(crt_bridge_set_beam_segment(impl->crt, v),     "crt.beamseg", v); }
void MetalPresenter::setShutter(float v)        { CRT_SET(crt_bridge_set_shutter(impl->crt, v),          "crt.shutter", v); }
void MetalPresenter::setScanlineSmoothing(float v) { CRT_SET(crt_bridge_set_scanline_smoothing(impl->crt, v), "crt.scansmooth", v); }
void MetalPresenter::setPatternSmooth(float v)  { CRT_SET(crt_bridge_set_pattern_smooth(impl->crt, v),   "crt.patsmooth", v); }
void MetalPresenter::setMaskScale(float v)      { CRT_SET(crt_bridge_set_mask_scale(impl->crt, v),       "crt.maskscale", v); }
void MetalPresenter::setPeakHighlights(float v) { CRT_SET(crt_bridge_set_peak_highlights(impl->crt, v),  "crt.peaks", v); }
void MetalPresenter::setPreset(int idx)         { if (idx < 0 || idx >= 6) return; CRT_SET(crt_bridge_set_preset(impl->crt, kCrtPresetNames[idx]), "crt.preset", idx); }

#undef CRT_SET

float
MetalPresenter::persistedValue(const char *key, float fallback) const
{
#ifdef USE_CRTENGINE
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *k = [NSString stringWithUTF8String:key];
    if ([d objectForKey:k] != nil)
        return [d floatForKey:k];
#endif
    (void) key;
    return fallback;
}

void
MetalPresenter::loadSettings()
{
#ifdef USE_CRTENGINE
    if (impl->crt == nullptr)
        return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    auto has = [d](const char *k) {
        return [d objectForKey:[NSString stringWithUTF8String:k]] != nil;
    };
    auto fv = [d](const char *k) {
        return [d floatForKey:[NSString stringWithUTF8String:k]];
    };
    // Only override settings the user has actually changed; untouched ones keep
    // the preset's value. Apply via the bridge directly (no re-persist).
    // Preset first (it re-applies preset defaults), then the picture/beam overrides.
    if (has("crt.preset")) {
        int pi = (int) lroundf(fv("crt.preset"));
        if (pi >= 0 && pi < 6) crt_bridge_set_preset(impl->crt, kCrtPresetNames[pi]);
    }
    if (has("crt.brightness"))   crt_bridge_set_brightness(impl->crt, fv("crt.brightness"));
    if (has("crt.contrast"))     crt_bridge_set_contrast(impl->crt, fv("crt.contrast"));
    if (has("crt.pattern"))      crt_bridge_set_phosphor_pattern(impl->crt, (int) lroundf(fv("crt.pattern")));
    if (has("crt.sharpness"))    crt_bridge_set_sharpness(impl->crt, fv("crt.sharpness"));
    if (has("crt.edge"))         crt_bridge_set_edge_focus(impl->crt, fv("crt.edge"));
    if (has("crt.bloom"))        crt_bridge_set_bloom(impl->crt, fv("crt.bloom"));
    if (has("crt.convergence"))  crt_bridge_set_convergence(impl->crt, fv("crt.convergence"));
    if (has("crt.hjitter"))      crt_bridge_set_h_jitter(impl->crt, fv("crt.hjitter"));
    if (has("crt.vjitter"))      crt_bridge_set_v_jitter(impl->crt, fv("crt.vjitter"));
    if (has("crt.shotnoise"))    crt_bridge_set_shot_noise(impl->crt, fv("crt.shotnoise"));
    if (has("crt.signalnoise"))  crt_bridge_set_signal_noise(impl->crt, fv("crt.signalnoise"));
    if (has("crt.hbandwidth"))   crt_bridge_set_h_bandwidth(impl->crt, fv("crt.hbandwidth"));
    if (has("crt.hfocus"))       crt_bridge_set_h_focus(impl->crt, fv("crt.hfocus"));
    if (has("crt.shutter"))      crt_bridge_set_shutter(impl->crt, fv("crt.shutter"));
    if (has("crt.scansmooth"))   crt_bridge_set_scanline_smoothing(impl->crt, fv("crt.scansmooth"));
    if (has("crt.patsmooth"))    crt_bridge_set_pattern_smooth(impl->crt, fv("crt.patsmooth"));
    if (has("crt.maskscale"))    crt_bridge_set_mask_scale(impl->crt, fv("crt.maskscale"));
    // Peak highlights (the old crt.hdrenabled/hdrboost keys are retired — EDR is no
    // longer a gain, so their values have no meaning under the new curve).
    if (has("crt.peaks"))        crt_bridge_set_peak_highlights(impl->crt, fv("crt.peaks"));
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
    bool           edr     = crt_bridge_edr_headroom(impl->crt) > 1.0f;
    MTLPixelFormat desired = edr ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;

    if (desired != impl->layerFormat) {
        impl->layerFormat = desired;
        if (!buildPipeline(impl))      // rebuild for the new attachment format
            return;
        impl->layer.pixelFormat = desired;
    }
    impl->layer.wantsExtendedDynamicRangeContent = edr;
    impl->layer.colorspace = CGColorSpaceCreateWithName(
        edr ? kCGColorSpaceExtendedLinearDisplayP3 : kCGColorSpaceDisplayP3);
    fprintf(stderr, "[MetalPresenter] display updated — EDR %s (headroom %.2f)\n",
            edr ? "ON" : "off", crt_bridge_edr_headroom(impl->crt));
#else
    (void) nsScreen;
#endif
}
