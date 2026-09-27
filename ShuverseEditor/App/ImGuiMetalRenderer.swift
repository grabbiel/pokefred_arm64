import CImGuiHost
import Foundation
import Metal
import MetalKit

/// Draws Dear ImGui meshes. This pass is independent of the map canvas:
/// its buffers, pipeline, and command queue are not the shared metatile rings.
final class ImGuiMetalRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private(set) var note: String?

    private var pipeline: MTLRenderPipelineState?
    private var pipelineFormat: MTLPixelFormat?
    private var fontTexture: MTLTexture?
    private var fontTexID: UInt64 = 0
    private var vertexBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?

    init?(device: MTLDevice?) {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        commandQueue.label = "imgui-queue"
    }

    func uploadFontIfNeeded() {
        guard fontTexture == nil else { return }
        var width: Int32 = 0
        var height: Int32 = 0
        guard let pixels = ig_host_font_pixels(&width, &height), width > 0, height > 0 else {
            note = "ImGui font atlas was empty."
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(width),
            height: Int(height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            note = "ImGui font texture allocation failed."
            return
        }
        texture.label = "ImGui Font"
        texture.replace(
            region: MTLRegionMake2D(0, 0, Int(width), Int(height)),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: Int(width) * 4
        )
        let texID = UInt64(UInt(bitPattern: Unmanaged.passUnretained(texture).toOpaque()))
        ig_host_font_set_tex_id(texID)
        fontTexture = texture
        fontTexID = texID
        note = nil
    }

    func encode(_ encoder: MTLRenderCommandEncoder, colorPixelFormat: MTLPixelFormat) {
        guard ensurePipeline(colorPixelFormat: colorPixelFormat), let pipeline, let fontTexture else {
            return
        }
        var data = IgHostDrawData()
        ig_host_draw_data(&data)
        guard data.valid != 0, data.total_vtx > 0, data.total_idx > 0, data.list_count > 0 else {
            return
        }
        let vertexStride = Int(IG_HOST_VERTEX_STRIDE)
        let indexStride = Int(IG_HOST_INDEX_STRIDE)
        guard let vertices = ensureBuffer(&vertexBuffer, byteCount: Int(data.total_vtx) * vertexStride, label: "imgui-vertices"),
              let indices = ensureBuffer(&indexBuffer, byteCount: Int(data.total_idx) * indexStride, label: "imgui-indices") else {
            note = "ImGui vertex buffer allocation failed."
            return
        }

        let fbWidth = Int(data.display_w * data.scale_x)
        let fbHeight = Int(data.display_h * data.scale_y)
        guard fbWidth > 0, fbHeight > 0 else { return }

        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(data.display_w * data.scale_x),
            height: Double(data.display_h * data.scale_y),
            znear: 0,
            zfar: 1
        ))
        var ortho = projection(
            left: data.display_x,
            right: data.display_x + data.display_w,
            top: data.display_y,
            bottom: data.display_y + data.display_h
        )
        encoder.setRenderPipelineState(pipeline)
        ortho.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                encoder.setVertexBytes(base, length: MemoryLayout<Float>.size * 16, index: 1)
            }
        }
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setFragmentTexture(fontTexture, index: 0)

        let indexType: MTLIndexType = indexStride == 2 ? .uint16 : .uint32
        var vertexBase = 0
        var indexBase = 0
        for listIndex in 0..<Int(data.list_count) {
            var list = IgHostDrawList()
            ig_host_draw_list(Int32(listIndex), &list)
            if list.vertex_count > 0, let source = list.vertices {
                vertices.contents().advanced(by: vertexBase * vertexStride).copyMemory(
                    from: source,
                    byteCount: Int(list.vertex_count) * vertexStride
                )
            }
            if list.index_count > 0, let source = list.indices {
                indices.contents().advanced(by: indexBase * indexStride).copyMemory(
                    from: source,
                    byteCount: Int(list.index_count) * indexStride
                )
            }
            for commandIndex in 0..<Int(list.command_count) {
                var command = IgHostDrawCmd()
                ig_host_draw_cmd(Int32(listIndex), Int32(commandIndex), &command)
                if command.is_callback != 0 || command.elem_count == 0 || command.tex_id == 0 {
                    continue
                }
                guard command.tex_id == fontTexID else { continue }
                var minX = (command.clip_x - data.display_x) * data.scale_x
                var minY = (command.clip_y - data.display_y) * data.scale_y
                var maxX = (command.clip_z - data.display_x) * data.scale_x
                var maxY = (command.clip_w - data.display_y) * data.scale_y
                if minX < 0 { minX = 0 }
                if minY < 0 { minY = 0 }
                if maxX > Float(fbWidth) { maxX = Float(fbWidth) }
                if maxY > Float(fbHeight) { maxY = Float(fbHeight) }
                if maxX <= minX || maxY <= minY { continue }
                let scissor = MTLScissorRect(
                    x: Int(minX),
                    y: Int(minY),
                    width: Int(maxX - minX),
                    height: Int(maxY - minY)
                )
                encoder.setScissorRect(scissor)
                let vertexOffset = (vertexBase + Int(command.vtx_offset)) * vertexStride
                encoder.setVertexBufferOffset(vertexOffset, index: 0)
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: Int(command.elem_count),
                    indexType: indexType,
                    indexBuffer: indices,
                    indexBufferOffset: (indexBase + Int(command.idx_offset)) * indexStride
                )
            }
            vertexBase += Int(list.vertex_count)
            indexBase += Int(list.index_count)
        }
    }

    private func ensureBuffer(_ buffer: inout MTLBuffer?, byteCount: Int, label: String) -> MTLBuffer? {
        if let buffer, buffer.length >= byteCount {
            return buffer
        }
        let created = device.makeBuffer(length: max(byteCount, 4096), options: .storageModeShared)
        created?.label = label
        buffer = created
        return created
    }

    private func ensurePipeline(colorPixelFormat: MTLPixelFormat) -> Bool {
        if let pipeline, pipelineFormat == colorPixelFormat {
            return true
        }
        guard let library = makeLibrary(),
              let vertex = library.makeFunction(name: "vertex_main"),
              let fragment = library.makeFunction(name: "fragment_main") else {
            return false
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.vertexDescriptor = vertexDescriptor()
        descriptor.rasterSampleCount = 1
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .invalid
        descriptor.stencilAttachmentPixelFormat = .invalid
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelineFormat = colorPixelFormat
            note = nil
            return true
        } catch {
            note = "ImGui pipeline failed: \(error.localizedDescription)"
            return false
        }
    }

    private func makeLibrary() -> MTLLibrary? {
        do {
            return try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            note = "ImGui shader failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func vertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].bufferIndex = 0
        descriptor.attributes[1].offset = 8
        descriptor.attributes[1].format = .float2
        descriptor.attributes[1].bufferIndex = 0
        descriptor.attributes[2].offset = 16
        descriptor.attributes[2].format = .uchar4
        descriptor.attributes[2].bufferIndex = 0
        descriptor.layouts[0].stride = Int(IG_HOST_VERTEX_STRIDE)
        descriptor.layouts[0].stepFunction = .perVertex
        descriptor.layouts[0].stepRate = 1
        return descriptor
    }

    /// Column-major-looking rows match `imgui_impl_metal.mm`'s ortho matrix,
    /// which Metal samples as a float4x4 from buffer(1).
    private func projection(left: Float, right: Float, top: Float, bottom: Float) -> [Float] {
        let near: Float = 0
        let far: Float = 1
        let rl = right - left
        let tb = top - bottom
        let fn = far - near
        guard rl != 0, tb != 0, fn != 0 else {
            return [Float](repeating: 0, count: 16)
        }
        return [
            2 / rl, 0, 0, 0,
            0, 2 / tb, 0, 0,
            0, 0, 1 / fn, 0,
            (right + left) / (left - right), (top + bottom) / (bottom - top), near / fn, 1,
        ]
    }

    // Shader body is the Dear ImGui Metal backend's vertex/fragment pair
    // (v1.91.9b docking), copied here so the package does not compile .mm.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4x4 projectionMatrix;
    };

    struct VertexIn {
        float2 position  [[attribute(0)]];
        float2 texCoords [[attribute(1)]];
        uchar4 color     [[attribute(2)]];
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoords;
        float4 color;
    };

    vertex VertexOut vertex_main(VertexIn in                 [[stage_in]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        VertexOut out;
        out.position = uniforms.projectionMatrix * float4(in.position, 0, 1);
        out.texCoords = in.texCoords;
        out.color = float4(in.color) / float4(255.0);
        return out;
    }

    fragment half4 fragment_main(VertexOut in [[stage_in]],
                                 texture2d<half, access::sample> texture [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, min_filter::linear, mag_filter::linear, mip_filter::linear);
        half4 texColor = texture.sample(linearSampler, in.texCoords);
        return half4(in.color) * texColor;
    }
    """
}
