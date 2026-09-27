import Foundation
import Metal
import ShuverseMapModel

enum MapShaders {
    static let vertexFunction = "map_vertex"
    static let spriteVertexFunction = "map_sprite_vertex"
    static let fragmentFunction = "map_fragment"
    static let tileFunction = "map_tile_overlay"

    static func compileOptions() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        return options
    }

    static func tileVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<Float>.stride * 2
        descriptor.layouts[0].stepFunction = .perVertex
        descriptor.layouts[0].stepRate = 1
        return descriptor
    }

    static func spriteVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<Float>.stride * 2
        descriptor.layouts[0].stepFunction = .perVertex
        descriptor.layouts[0].stepRate = 1

        descriptor.attributes[1].format = .float2
        descriptor.attributes[1].offset = MapGPULayout.instanceCenterOffset
        descriptor.attributes[1].bufferIndex = 1
        descriptor.attributes[2].format = .float2
        descriptor.attributes[2].offset = MapGPULayout.instanceHalfOffset
        descriptor.attributes[2].bufferIndex = 1
        descriptor.attributes[3].format = .float4
        descriptor.attributes[3].offset = MapGPULayout.instanceColorOffset
        descriptor.attributes[3].bufferIndex = 1
        descriptor.attributes[4].format = .float
        descriptor.attributes[4].offset = MapGPULayout.instanceDepthOffset
        descriptor.attributes[4].bufferIndex = 1
        descriptor.layouts[1].stride = MapGPULayout.quadInstanceBytes
        descriptor.layouts[1].stepFunction = .perInstance
        descriptor.layouts[1].stepRate = 1
        return descriptor
    }

    static func depthStencilDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.label = "map-depth-less"
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    /// MSL compiled at runtime with `makeLibrary(source:)`. CI extracts this
    /// string and runs `metal -c`. `Uniforms` is `MapGPUUniforms` (64 bytes).
    /// Vertex and fragment inputs use `[[stage_in]]`. `map_tile_overlay` is
    /// kept for a future imageblock path. macOS does not attach it: the tile
    /// render-pipeline APIs are not used by this app.
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float originX;
        float originY;
        float viewportWidth;
        float viewportHeight;
        float pointsPerMetatile;
        float groundDepth;
        float pixelScale;
        float selectionThickness;
        uint gridWidth;
        uint gridHeight;
        int selectedX;
        int selectedY;
        uint overlayFlags;
        uint tileWidth;
        uint tileHeight;
        float collisionTintScale;
    };

    struct TileIn {
        float2 corner [[attribute(0)]];
    };

    struct SpriteIn {
        float2 corner [[attribute(0)]];
        float2 center [[attribute(1)]];
        float2 halfSize [[attribute(2)]];
        float4 color [[attribute(3)]];
        float layerDepth [[attribute(4)]];
    };

    struct Varying {
        float4 position [[position]];
        float4 color;
    };

    constant uint OverlaySelection = 1u;
    constant uint OverlayCollision = 2u;

    float2 world_to_ndc(float2 world, Uniforms u) {
        float2 pixel = (world - float2(u.originX, u.originY)) * u.pointsPerMetatile;
        float width = max(u.viewportWidth, 1.0);
        float height = max(u.viewportHeight, 1.0);
        return float2(
            (pixel.x / width) * 2.0 - 1.0,
            1.0 - (pixel.y / height) * 2.0
        );
    }

    vertex Varying map_vertex(
        TileIn in [[stage_in]],
        constant Uniforms &u [[buffer(1)]],
        const device uint *grid [[buffer(2)]],
        const device float4 *palette [[buffer(3)]],
        uint instanceID [[instance_id]]
    ) {
        uint width = max(u.gridWidth, 1u);
        uint x = instanceID % width;
        uint y = instanceID / width;
        uint word = grid[instanceID];
        uint metatileId = word & 1023u;
        float2 world = float2(float(x), float(y)) + in.corner;
        Varying out;
        out.position = float4(world_to_ndc(world, u), u.groundDepth, 1.0);
        out.color = palette[metatileId];
        return out;
    }

    vertex Varying map_sprite_vertex(
        SpriteIn in [[stage_in]],
        constant Uniforms &u [[buffer(2)]]
    ) {
        float2 world = in.center + in.corner * in.halfSize;
        Varying out;
        out.position = float4(world_to_ndc(world, u), in.layerDepth, 1.0);
        out.color = in.color;
        return out;
    }

    fragment float4 map_fragment(Varying in [[stage_in]]) {
        return in.color;
    }

    struct TilePixel {
        float4 color [[color(0)]];
    };

    // Future TBDR imageblock overlay. Not bound on macOS.
    // World math matches MapTileOverlay.world / hitsSelectionBorder.
    // Selection quads are the v1 outline, so this kernel must not run
    // alongside them or the border is drawn twice.
    kernel void map_tile_overlay(
        imageblock<TilePixel> imageBlock,
        ushort2 tid [[thread_position_in_threadgroup]],
        uint2 tgPos [[threadgroup_position_in_grid]],
        constant Uniforms &u [[buffer(0)]],
        const device uint *grid [[buffer(1)]]
    ) {
        TilePixel pixel = imageBlock.read(tid);
        if (u.overlayFlags != 0u && u.tileWidth > 0u && u.pointsPerMetatile > 0.0) {
            uint2 pix = tgPos * uint2(u.tileWidth, u.tileHeight) + uint2(uint(tid.x), uint(tid.y));
            float scale = max(u.pixelScale, 1.0);
            float worldX = u.originX + ((float(pix.x) / scale) + 0.5) / u.pointsPerMetatile;
            float worldY = u.originY + ((float(pix.y) / scale) + 0.5) / u.pointsPerMetatile;
            if ((u.overlayFlags & OverlayCollision) != 0u && u.gridWidth > 0u) {
                int cellX = int(floor(worldX));
                int cellY = int(floor(worldY));
                if (cellX >= 0 && cellY >= 0 && uint(cellX) < u.gridWidth && uint(cellY) < u.gridHeight) {
                    uint word = grid[(uint(cellY) * u.gridWidth) + uint(cellX)];
                    uint attr = (word >> 10u) & 63u;
                    if (attr != 0u) {
                        pixel.color.rgb *= u.collisionTintScale;
                    }
                }
            }
            if ((u.overlayFlags & OverlaySelection) != 0u && u.selectedX >= 0 && u.selectedY >= 0) {
                float lx = worldX - float(u.selectedX);
                float ly = worldY - float(u.selectedY);
                float t = u.selectionThickness;
                bool inside = lx >= 0.0 && ly >= 0.0 && lx < 1.0 && ly < 1.0;
                bool border = lx < t || ly < t || lx > (1.0 - t) || ly > (1.0 - t);
                if (inside && border) {
                    pixel.color = float4(1.0, 0.86, 0.25, 1.0);
                }
            }
        }
        imageBlock.write(pixel, tid);
    }
    """
}
