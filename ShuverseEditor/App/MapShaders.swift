import Foundation
import Metal
import ShuverseMapModel

enum MapShaders {
    static let vertexFunction = "map_vertex"
    static let canopyVertexFunction = "map_canopy_vertex"
    static let spriteVertexFunction = "map_sprite_vertex"
    static let fragmentFunction = "map_fragment"
    static let tileFragmentFunction = "map_tile_fragment"
    static let canopyFragmentFunction = "map_canopy_fragment"
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

    /// Tile corners in buffer 0. Per-instance cell index and depth in buffer 1,
    /// same slots as the sprite quads. Uniforms are buffer 2 and the grid is buffer 3.
    static func canopyVertexDescriptor() -> MTLVertexDescriptor {
        let descriptor = MTLVertexDescriptor()
        descriptor.attributes[0].format = .float2
        descriptor.attributes[0].offset = 0
        descriptor.attributes[0].bufferIndex = 0
        descriptor.layouts[0].stride = MemoryLayout<Float>.stride * 2
        descriptor.layouts[0].stepFunction = .perVertex
        descriptor.layouts[0].stepRate = 1

        descriptor.attributes[1].format = .uint
        descriptor.attributes[1].offset = MapGPULayout.canopyCellOffset
        descriptor.attributes[1].bufferIndex = 1
        descriptor.attributes[2].format = .float
        descriptor.attributes[2].offset = MapGPULayout.canopyDepthOffset
        descriptor.attributes[2].bufferIndex = 1
        descriptor.layouts[1].stride = MapGPULayout.canopyInstanceBytes
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
    /// Vertex and fragment inputs use `[[stage_in]]`. Ground fragments sample
    /// a shared r8Uint index atlas and an RGB555 palette. `map_tile_overlay`
    /// is kept for a future imageblock path. macOS does not attach it: the
    /// tile render-pipeline APIs are not used by this app.
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
        float2 tileUV;
        float metatileId;
    };

    constant uint AtlasTilesPerRow = 16u;
    constant uint MetatilePixels = 16u;
    constant uint TilePixels = 8u;

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
        out.color = float4(1.0);
        out.tileUV = in.corner;
        out.metatileId = float(metatileId);
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
        out.tileUV = float2(0.0);
        out.metatileId = 0.0;
        return out;
    }

    struct CanopyIn {
        float2 corner [[attribute(0)]];
        uint cellIndex [[attribute(1)]];
        float layerDepth [[attribute(2)]];
    };

    // Same grid lookup as map_vertex. Depth comes from the instance
    // (`MapDepth.canopy`) so the leaves sort in front of ground.
    vertex Varying map_canopy_vertex(
        CanopyIn in [[stage_in]],
        constant Uniforms &u [[buffer(2)]],
        const device uint *grid [[buffer(3)]]
    ) {
        uint width = max(u.gridWidth, 1u);
        uint index = in.cellIndex;
        uint x = index % width;
        uint y = index / width;
        uint word = grid[index];
        uint metatileId = word & 1023u;
        float2 world = float2(float(x), float(y)) + in.corner;
        Varying out;
        out.position = float4(world_to_ndc(world, u), in.layerDepth, 1.0);
        out.color = float4(1.0);
        out.tileUV = in.corner;
        out.metatileId = float(metatileId);
        return out;
    }

    fragment float4 map_fragment(Varying in [[stage_in]]) {
        return in.color;
    }

    // Quadrant, flip, and index-0 rules match GBATileset.sample.
    fragment float4 map_tile_fragment(
        Varying in [[stage_in]],
        texture2d<uint, access::read> indices [[texture(0)]],
        const device ushort *palette [[buffer(0)]],
        const device ushort *metatiles [[buffer(1)]]
    ) {
        float2 local = clamp(in.tileUV, 0.0, 0.9999);
        uint x = min(uint(local.x * float(MetatilePixels)), MetatilePixels - 1u);
        uint y = min(uint(local.y * float(MetatilePixels)), MetatilePixels - 1u);
        uint tx = x / TilePixels;
        uint ty = y / TilePixels;
        uint metatileId = min(uint(in.metatileId + 0.5), 1023u);
        float4 color = float4(0.0);
        for (uint layer = 0u; layer < 2u; layer++) {
            uint slot = layer * 4u + ty * 2u + tx;
            uint raw = uint(metatiles[metatileId * 8u + slot]);
            uint tileId = raw & 1023u;
            uint px = x % TilePixels;
            uint py = y % TilePixels;
            if (((raw >> 10u) & 1u) != 0u) {
                px = (TilePixels - 1u) - px;
            }
            if (((raw >> 11u) & 1u) != 0u) {
                py = (TilePixels - 1u) - py;
            }
            uint pal = (raw >> 12u) & 15u;
            uint ax = (tileId % AtlasTilesPerRow) * TilePixels + px;
            uint ay = (tileId / AtlasTilesPerRow) * TilePixels + py;
            uint index = indices.read(uint2(ax, ay)).r;
            if (index == 0u) {
                continue;
            }
            uint packed = uint(palette[pal * 16u + index]);
            float r = float(packed & 31u) / 31.0;
            float g = float((packed >> 5u) & 31u) / 31.0;
            float b = float((packed >> 10u) & 31u) / 31.0;
            color = float4(r, g, b, 1.0);
        }
        return color;
    }

    // Top layer only (the tree leaves). Index 0 discards so the hole does not
    // write depth and the sprite stub can show through onto the ground.
    fragment float4 map_canopy_fragment(
        Varying in [[stage_in]],
        texture2d<uint, access::read> indices [[texture(0)]],
        const device ushort *palette [[buffer(0)]],
        const device ushort *metatiles [[buffer(1)]]
    ) {
        float2 local = clamp(in.tileUV, 0.0, 0.9999);
        uint x = min(uint(local.x * float(MetatilePixels)), MetatilePixels - 1u);
        uint y = min(uint(local.y * float(MetatilePixels)), MetatilePixels - 1u);
        uint tx = x / TilePixels;
        uint ty = y / TilePixels;
        uint metatileId = min(uint(in.metatileId + 0.5), 1023u);
        uint layer = 1u;
        uint slot = layer * 4u + ty * 2u + tx;
        uint raw = uint(metatiles[metatileId * 8u + slot]);
        uint tileId = raw & 1023u;
        uint px = x % TilePixels;
        uint py = y % TilePixels;
        if (((raw >> 10u) & 1u) != 0u) {
            px = (TilePixels - 1u) - px;
        }
        if (((raw >> 11u) & 1u) != 0u) {
            py = (TilePixels - 1u) - py;
        }
        uint pal = (raw >> 12u) & 15u;
        uint ax = (tileId % AtlasTilesPerRow) * TilePixels + px;
        uint ay = (tileId / AtlasTilesPerRow) * TilePixels + py;
        uint index = indices.read(uint2(ax, ay)).r;
        if (index == 0u) {
            discard_fragment();
        }
        uint packed = uint(palette[pal * 16u + index]);
        float r = float(packed & 31u) / 31.0;
        float g = float((packed >> 5u) & 31u) / 31.0;
        float b = float((packed >> 10u) & 31u) / 31.0;
        return float4(r, g, b, 1.0);
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
