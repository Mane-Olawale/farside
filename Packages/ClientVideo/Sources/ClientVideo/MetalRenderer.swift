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

/// What one refresh draws besides the video's pixels: where the video frame goes, and the cursor.
public struct RenderScene: Sendable, Equatable {
    /// Where the whole stream frame lands, in drawable pixels with the origin at the top left.
    /// It may extend past the drawable when zoomed. Nil fits the frame, letterboxed.
    public var videoRect: CGRect?
    public var cursor: CursorPlacement?

    public init(videoRect: CGRect? = nil, cursor: CursorPlacement? = nil) {
        self.videoRect = videoRect
        self.cursor = cursor
    }
}

/// A cursor image, set once with `MetalRenderer.setCursorImage`, and where to draw it.
public struct CursorPlacement: Sendable, Equatable {
    public var id: UInt32
    /// In drawable pixels, origin top left: the image's top left at the hot spot's offset.
    public var rect: CGRect

    public init(id: UInt32, rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

/// Draws decoded 4:2:0 video-range frames into a `CAMetalLayer` with a BT.709 conversion (plan
/// section 8, renderer). Textures wrap the decoded planes without a copy. The vertex stage places
/// the frame where the viewport says (fit, fill, zoom, pan), and the cursor is a second textured
/// quad in the same pass.
///
/// The product presents through `VideoPresenter`, which paces from a display link and never
/// waits for a drawable. `draw` is the spike rigs' path: it blocks in `nextDrawable`, which
/// section 8 no longer allows in the product.
public final class MetalRenderer: @unchecked Sendable {
    let layer: CAMetalLayer
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let cursorPipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let drawableSize = Mutex(CGSize.zero)
    private let cursors = Mutex<[UInt32: TextureBox]>([:])

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

        // The cursor is premultiplied BGRA, blended over the video.
        let cursorDescriptor = MTLRenderPipelineDescriptor()
        cursorDescriptor.vertexFunction = library.makeFunction(name: "videoVertex")
        cursorDescriptor.fragmentFunction = library.makeFunction(name: "cursorFragment")
        let attachment = cursorDescriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let cursorPipeline = try? device.makeRenderPipelineState(descriptor: cursorDescriptor) else { return nil }

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
        self.cursorPipeline = cursorPipeline
        self.textureCache = cache
    }

    /// Uploads a cursor image for later `CursorPlacement`s with this id. Any thread.
    @discardableResult
    public func setCursorImage(id: UInt32, image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 512, height <= 512 else { return false }
        // Premultiplied BGRA, as the blend expects.
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard drawn, let texture = device.makeTexture(descriptor: descriptor) else { return false }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        cursors.withLock { $0[id] = TextureBox(texture: texture) }
        return true
    }

    public func hasCursorImage(id: UInt32) -> Bool { cursors.withLock { $0[id] != nil } }

    /// Call on the main thread when the hosting view resizes. Size is in pixels.
    public func setDrawableSize(_ size: CGSize) {
        layer.drawableSize = size
        drawableSize.withLock { $0 = size }
    }

    /// Spike rigs only: waits for a drawable, then draws one frame. `presented` runs once the frame
    /// reached the display, or is not called if the frame was never shown.
    public func draw(_ pixels: CVPixelBuffer, presented: @escaping @Sendable (RenderTimes) -> Void) {
        guard drawableSize.withLock({ $0.width > 0 && $0.height > 0 }), let drawable = layer.nextDrawable() else { return }
        _ = encode(pixels, scene: RenderScene(), into: drawable, acquiredTicks: HostClock.now(), presented: presented)
    }

    /// Draws one frame into a drawable the caller already holds and presents it. Returns false if
    /// nothing was submitted.
    func encode(_ pixels: CVPixelBuffer, scene: RenderScene, into drawable: CAMetalDrawable, acquiredTicks acquired: UInt64,
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

        let videoSize = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        var videoQuad = Self.ndc(scene.videoRect ?? Self.fit(videoSize, in: target), in: target)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&videoQuad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        let cursorTexture = scene.cursor.flatMap { cursor in cursors.withLock { $0[cursor.id] } }
        if let cursor = scene.cursor, let box = cursorTexture {
            var quad = Self.ndc(cursor.rect, in: target)
            encoder.setRenderPipelineState(cursorPipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentTexture(box.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        let keep = TextureHold(luma: luma, chroma: chroma)
        drawable.addPresentedHandler { drawable in
            let time = drawable.presentedTime
            if time > 0 {
                presented(RenderTimes(acquiredTicks: acquired, committedTicks: keep.committed.withLock { $0 }, presentedSeconds: time))
            }
        }
        buffer.addCompletedHandler { _ in
            _ = keep
            _ = cursorTexture
        }
        buffer.present(drawable)
        keep.committed.withLock { $0 = HostClock.now() }
        buffer.commit()
        return true
    }

    /// The frame letterboxed into the target, both in pixels.
    static func fit(_ size: CGSize, in target: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: target) }
        let scale = min(target.width / size.width, target.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (target.width - width) / 2, y: (target.height - height) / 2, width: width, height: height)
    }

    /// A rect in top-left pixels as (left, top, right, bottom) in normalized device coordinates.
    static func ndc(_ rect: CGRect, in target: CGSize) -> SIMD4<Float> {
        SIMD4(Float(rect.minX / target.width * 2 - 1), Float(1 - rect.minY / target.height * 2),
              Float(rect.maxX / target.width * 2 - 1), Float(1 - rect.maxY / target.height * 2))
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
    /// An `MTLTexture` that crosses threads; it is immutable once uploaded.
    final class TextureBox: @unchecked Sendable {
        let texture: MTLTexture
        init(texture: MTLTexture) { self.texture = texture }
    }

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

    constant float2 coords[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };

    // quad: left, top, right, bottom in normalized device coordinates.
    vertex VideoVertex videoVertex(uint id [[vertex_id]], constant float4 &quad [[buffer(0)]]) {
        float2 corners[4] = { float2(quad.x, quad.w), float2(quad.z, quad.w), float2(quad.x, quad.y), float2(quad.z, quad.y) };
        VideoVertex out;
        out.position = float4(corners[id], 0, 1);
        out.uv = coords[id];
        return out;
    }

    fragment float4 cursorFragment(VideoVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return image.sample(s, in.uv);
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
