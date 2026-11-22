import CoreVideo
import Foundation
import MediaCore
import Metal
import QuartzCore
import Synchronization

/// Host-clock times for one drawn frame.
public struct RenderTimes: Sendable {
    /// When `nextDrawable` returned.
    public let acquiredTicks: UInt64
    /// When the command buffer was committed with the present.
    public let committedTicks: UInt64
    /// When the frame reached the display, in `CACurrentMediaTime` seconds.
    public let presentedSeconds: CFTimeInterval
}

/// Draws decoded 4:2:0 video-range frames into a `CAMetalLayer` with a BT.709 conversion and an
/// aspect fit (plan section 8, renderer). Textures wrap the decoded planes without a copy.
///
/// The product presents through `VideoPresenter`, which paces from a display link and never
/// waits for a drawable. `draw` is the spike rigs' path: it blocks in `nextDrawable`, which
/// section 8 no longer allows in the product. Phase 2 adds the viewport transform and the cursor.
public final class MetalRenderer: @unchecked Sendable {
    let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let drawableSize = Mutex(CGSize.zero)

    /// Call on the main thread, where the layer was created.
    public init?(layer: CAMetalLayer) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache,
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "videoVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "videoFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        #if os(macOS)
        layer.displaySyncEnabled = true
        #endif

        self.layer = layer
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.textureCache = cache
    }

    /// Call on the main thread when the hosting view resizes. Size is in pixels.
    public func setDrawableSize(_ size: CGSize) {
        layer.drawableSize = size
        drawableSize.withLock { $0 = size }
    }

    /// Spike rigs only: waits for a drawable, then draws one frame. `presented` runs once the frame
    /// reached the display, or is not called if the frame was never shown.
    public func draw(_ pixels: CVPixelBuffer, presented: @escaping @Sendable (RenderTimes) -> Void) {
        guard drawableSize.withLock({ $0.width > 0 && $0.height > 0 }), let drawable = layer.nextDrawable() else { return }
        _ = encode(pixels, into: drawable, acquiredTicks: HostClock.now(), presented: presented)
    }

    /// Draws one frame into a drawable the caller already holds and presents it. Returns false if
    /// nothing was submitted.
    func encode(_ pixels: CVPixelBuffer, into drawable: CAMetalDrawable, acquiredTicks acquired: UInt64,
                presented: @escaping @Sendable (RenderTimes) -> Void) -> Bool {
        let target = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        guard target.width > 0, target.height > 0,
              let luma = texture(pixels, plane: 0, format: .r8Unorm),
              let chroma = texture(pixels, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma),
              let buffer = queue.makeCommandBuffer()
        else { return false }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }

        let videoAspect = Float(CVPixelBufferGetWidth(pixels)) / Float(CVPixelBufferGetHeight(pixels))
        let viewAspect = Float(target.width / target.height)
        var scale: SIMD2<Float> = videoAspect > viewAspect
            ? [1, viewAspect / videoAspect]
            : [videoAspect / viewAspect, 1]

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        let keep = TextureHold(luma: luma, chroma: chroma)
        drawable.addPresentedHandler { drawable in
            let time = drawable.presentedTime
            if time > 0 {
                presented(RenderTimes(acquiredTicks: acquired, committedTicks: keep.committed.withLock { $0 }, presentedSeconds: time))
            }
        }
        buffer.addCompletedHandler { _ in _ = keep }
        buffer.present(drawable)
        keep.committed.withLock { $0 = HostClock.now() }
        buffer.commit()
        return true
    }

    private func texture(_ pixels: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixels, nil, format,
            CVPixelBufferGetWidthOfPlane(pixels, plane), CVPixelBufferGetHeightOfPlane(pixels, plane),
            plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// Keeps the Core Video textures, and so the decoded surface, alive until the GPU is done,
    /// and carries the commit time to the presented handler.
    private final class TextureHold: @unchecked Sendable {
        let luma: CVMetalTexture
        let chroma: CVMetalTexture
        let committed = Mutex<UInt64>(0)
        init(luma: CVMetalTexture, chroma: CVMetalTexture) {
            self.luma = luma
            self.chroma = chroma
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VideoVertex {
        float4 position [[position]];
        float2 uv;
    };

    constant float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    constant float2 coords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

    vertex VideoVertex videoVertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
        VideoVertex out;
        out.position = float4(corners[id] * scale, 0, 1);
        out.uv = coords[id];
        return out;
    }

    // BT.709, video range.
    fragment float4 videoFragment(VideoVertex in [[stage_in]],
                                  texture2d<float> luma [[texture(0)]],
                                  texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (luma.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (chroma.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y,
                            y - 0.1873 * c.x - 0.4681 * c.y,
                            y + 1.8556 * c.x);
        return float4(saturate(rgb), 1);
    }
    """
}
