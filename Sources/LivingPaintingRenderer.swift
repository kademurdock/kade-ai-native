import Foundation
import Metal
import MetalKit
import UIKit

/// Oct 16 2026: draws a living painting with the phone's own graphics chip.
/// One grid of textured triangles, drawn once per layer (neutral panel cut by
/// the head matte, dissolving expressions, speaking mouths, closed eyes), each
/// layer with its own texture coordinates so every panel stays registered to
/// the same moving grid. Only the grid's vertex positions change per frame.
///
/// The shader is compiled from source at first use (no offline Metal
/// toolchain needed to build the app). Pictures load once per character and
/// are shared by every view on screen; nothing here is ever sent anywhere.
final class LivingPaintingResources {
    let rig: LivingPaintingRig
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// The rest grid: texture coordinates of an unwarped layer and, for every
    /// layer, the source point its masks are measured at.
    let restBuffer: MTLBuffer
    let matte: MTLTexture
    private let sheets: [LivingPaintingPanel.Sheet: MTLTexture]
    private var flowBuffers: [String: MTLBuffer] = [:]
    private let lock = NSLock()

    enum LoadError: Error { case unavailable(String) }

    private static var cache: [String: LivingPaintingResources] = [:]
    private static let cacheLock = NSLock()

    /// The character's resources, loaded once. Throws when the rig file, a
    /// picture or the GPU is missing; callers then keep the sliced portrait.
    static func shared(rigName: String) throws -> LivingPaintingResources {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[rigName] { return cached }
        guard let url = Bundle.main.url(forResource: rigName, withExtension: "json") else {
            throw LoadError.unavailable("no \(rigName).json in the bundle")
        }
        let rig = try LivingPaintingRig(data: Data(contentsOf: url))
        let made = try LivingPaintingResources(rig: rig)
        cache[rigName] = made
        return made
    }

    /// Frees the pictures when the app is told memory is short; the next
    /// living painting on screen loads them again.
    static func purge() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    init(rig: LivingPaintingRig) throws {
        self.rig = rig
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw LoadError.unavailable("no Metal device")
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let vertex = library.makeFunction(name: "lp_vertex"),
              let fragment = library.makeFunction(name: "lp_fragment") else {
            throw LoadError.unavailable("shader functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Premultiplied source-over, like every other layer SwiftUI composes.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let indices = rig.triangles
        guard let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 2, options: []) else {
            throw LoadError.unavailable("index buffer")
        }
        self.indexBuffer = indexBuffer
        indexCount = indices.count
        var rest = [Float](repeating: 0, count: rig.vertexCount * 2)
        for i in 0..<rig.vertexCount {
            rest[i * 2] = Float(rig.restX[i])
            rest[i * 2 + 1] = Float(rig.restY[i])
        }
        guard let restBuffer = device.makeBuffer(bytes: rest, length: rest.count * 4, options: []) else {
            throw LoadError.unavailable("rest buffer")
        }
        self.restBuffer = restBuffer

        let loader = MTKTextureLoader(device: device)
        func texture(_ asset: String) throws -> MTLTexture {
            guard let image = UIImage(named: asset)?.cgImage else { throw LoadError.unavailable("picture \(asset)") }
            // The pictures' own sRGB bytes, blended as stored, as SwiftUI does.
            return try loader.newTexture(cgImage: image, options: [
                .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue])
        }
        let sheets = rig.file.sheets
        self.sheets = [.faces: try texture(sheets.faces), .mouths: try texture(sheets.mouths),
                       .nuance: try texture(sheets.nuance)]
        matte = try texture(rig.file.mask.asset)
    }

    func texture(_ sheet: LivingPaintingPanel.Sheet) -> MTLTexture? { sheets[sheet] }

    /// Texture coordinates for a layer: the rest grid moved by the panel's
    /// flow, so the panel's feature lands where the neutral one is drawn.
    func uvBuffer(_ flowKey: String?) -> MTLBuffer? {
        guard let key = flowKey else { return restBuffer }
        lock.lock()
        defer { lock.unlock() }
        if let made = flowBuffers[key] { return made }
        guard let flow = rig.flows[key] else { return nil }
        var uv = [Float](repeating: 0, count: rig.vertexCount * 2)
        for i in 0..<rig.vertexCount {
            uv[i * 2] = Float(rig.restX[i] + flow[i * 2])
            uv[i * 2 + 1] = Float(rig.restY[i] + flow[i * 2 + 1])
        }
        let made = device.makeBuffer(bytes: uv, length: uv.count * 4, options: [])
        flowBuffers[key] = made
        return made
    }

    /// Per-layer constants, five float4s (the shader's LPLayer).
    func uniforms(_ layer: LivingPaintingLayer) -> [SIMD4<Float>] {
        let file = rig.file
        let pitch = file.sheets.pitch
        let origin = SIMD2<Double>(Double(layer.panel.index % 3) * pitch, Double(layer.panel.index / 3) * pitch)
        let size = texture(layer.panel.sheet).map { SIMD2<Double>(Double($0.width), Double($0.height)) } ?? SIMD2(1, 1)
        let region = rig.region(layer.region)
        return [
            SIMD4<Float>(Float(region.cx), Float(region.cy), Float(region.rx), Float(region.ry)),
            SIMD4<Float>(Float(origin.x), Float(origin.y), Float(size.x), Float(size.y)),
            SIMD4<Float>(Float(layer.alpha), Float(region.inner), layer.region == .head ? 0 : 1, 0),
            SIMD4<Float>(Float(file.mask.x), Float(file.mask.y), Float(file.mask.side), 0),
            SIMD4<Float>(Float(file.core.x), Float(file.core.y), Float(file.core.rx), Float(file.core.ry)),
        ]
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct LPOut {
        float4 position [[position]];
        float2 uv;
        float2 rest;
    };

    vertex LPOut lp_vertex(uint vid [[vertex_id]],
                           const device float2 *positions [[buffer(0)]],
                           const device float2 *uvs [[buffer(1)]],
                           const device float2 *rests [[buffer(2)]],
                           constant float4 &place [[buffer(3)]]) {
        LPOut out;
        float2 p = positions[vid];
        out.position = float4(p.x * place.x + place.z, p.y * place.y + place.w, 0.0, 1.0);
        out.uv = uvs[vid];
        out.rest = rests[vid];
        return out;
    }

    struct LPLayer {
        float4 region;
        float4 sheet;
        float4 look;
        float4 matte;
        float4 core;
    };

    fragment float4 lp_fragment(LPOut in [[stage_in]],
                                texture2d<float> art [[texture(0)]],
                                texture2d<float> matte [[texture(1)]],
                                constant LPLayer &layer [[buffer(0)]]) {
        constexpr sampler smooth(coord::normalized, filter::linear, address::clamp_to_edge);
        float4 color = art.sample(smooth, (layer.sheet.xy + in.uv) / layer.sheet.zw);
        float alpha;
        if (layer.look.z < 0.5) {
            float2 m = (in.rest - layer.matte.xy) / layer.matte.z;
            float inside = step(0.0, m.x) * step(0.0, m.y) * step(m.x, 1.0) * step(m.y, 1.0);
            float cut = matte.sample(smooth, m).a * inside;
            float2 e = (in.rest - layer.core.xy) / layer.core.zw;
            alpha = max(cut, dot(e, e) <= 1.0 ? 1.0 : 0.0);
        } else {
            float2 e = (in.rest - layer.region.xy) / layer.region.zw;
            alpha = clamp((1.0 - length(e)) / max(1e-4, 1.0 - layer.look.y), 0.0, 1.0);
        }
        alpha *= layer.look.x;
        return float4(color.rgb * alpha, alpha);
    }
    """
}

/// One view's drawing: its own frame state and vertex buffers, sharing the
/// character's resources. Drawn on demand only, when SwiftUI hands it a new
/// state (the portrait's own budgeted clock), never on a timer of its own.
final class LivingPaintingDrawer: NSObject, MTKViewDelegate {
    let resources: LivingPaintingResources
    var state = LivingPaintingState()
    private var positions: [MTLBuffer] = []
    private var next = 0
    private let inFlight = DispatchSemaphore(value: 3)
    /// Milliseconds the last frame's grid took on the CPU (DEBUG readouts).
    private(set) var lastGridMilliseconds = 0.0

    init(resources: LivingPaintingResources) {
        self.resources = resources
        let length = resources.rig.vertexCount * 2 * MemoryLayout<Float>.stride
        for _ in 0..<3 {
            if let buffer = resources.device.makeBuffer(length: length, options: .storageModeShared) {
                positions.append(buffer)
            }
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard positions.count == 3, let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        inFlight.wait()
        let buffer = positions[next]
        next = (next + 1) % 3
        let started = CFAbsoluteTimeGetCurrent()
        resources.rig.vertices(state, into: buffer.contents().bindMemory(to: Float.self,
            capacity: resources.rig.vertexCount * 2))
        lastGridMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        guard let commands = resources.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal()
            return
        }
        let panel = Float(resources.rig.file.panel)
        // Panel pixels to clip space: the view is exactly the panel's frame.
        var place = SIMD4<Float>(2 / panel, -2 / panel, -1, 1)
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBuffer(resources.restBuffer, offset: 0, index: 2)
        encoder.setVertexBytes(&place, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
        encoder.setFragmentTexture(resources.matte, index: 1)
        for layer in resources.rig.layers(state) {
            guard let uv = resources.uvBuffer(layer.flowKey),
                  let art = resources.texture(layer.panel.sheet) else { continue }
            var constants = resources.uniforms(layer)
            encoder.setVertexBuffer(uv, offset: 0, index: 1)
            encoder.setFragmentTexture(art, index: 0)
            encoder.setFragmentBytes(&constants, length: constants.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: resources.indexCount,
                indexType: .uint16, indexBuffer: resources.indexBuffer, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        commands.present(drawable)
        let semaphore = inFlight
        commands.addCompletedHandler { _ in semaphore.signal() }
        commands.commit()
    }
}
