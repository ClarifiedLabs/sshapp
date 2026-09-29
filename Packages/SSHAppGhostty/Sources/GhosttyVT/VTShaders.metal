// Build-time-compiled shaders for the GhosttyVT Metal renderer. SwiftPM
// compiles this file into the target's default metallib, so renderer setup
// never pays runtime MSL compilation. Loaded via VTShaderLibrary.
#include <metal_stdlib>
using namespace metal;

// MARK: - Cell pipeline (VTMetalRasterizer)

/// One drawn quad: glyph, fill, decoration, cursor or image. Layout matches
/// Instance in VTMetalRasterizer.swift (float4 alignment pads both to 48).
struct VTInstance {
    float4 dst;    // x, y, width, height in points
    float4 uv;     // normalized origin + size in the bound texture
    uint  color;   // packed rgb: r | g << 8 | b << 16
    uint  flags;   // bit 0: faint (alpha 0.5); bit 1: color glyph pixels
};

struct VTCellUniforms { float2 viewport; };  // points

struct VTCellRaster {
    float4 position [[position]];
    float2 uv;
    float4 color [[flat]];  // premultiplied tint, constant per instance
};

struct VTImageSample { uint2 imageSize; uint2 origin; uint2 size; uint2 pageOrigin; };

vertex VTCellRaster vt_cell_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device VTInstance* instances [[buffer(0)]],
                                   constant VTCellUniforms& uniforms [[buffer(1)]]) {
    const device VTInstance& in = instances[iid];
    // Triangle-strip corner order: 0 = top-left, 1 = top-right, 2 = bottom-left, 3 = bottom-right.
    float2 corner = float2(vid == 1 || vid == 3, vid == 2 || vid == 3);
    float2 position = in.dst.xy + corner * in.dst.zw;
    // Alpha is 1.0 or exactly 0.5 (faint); both multiplies are exact in binary
    // floating point, so the tint matches the former CPU computation exactly.
    float alpha = (in.flags & 1u) != 0u ? 0.5 : 1.0;
    float3 rgb = float3(float(in.color & 0xffu), float((in.color >> 8) & 0xffu),
                        float((in.color >> 16) & 0xffu)) / 255.0;
    float4 tint = (in.flags & 2u) != 0u ? float4(alpha) : float4(rgb * alpha, alpha);
    return { float4(position.x / uniforms.viewport.x * 2 - 1,
                    1 - position.y / uniforms.viewport.y * 2, 0, 1),
             in.uv.xy + corner * in.uv.zw, tint };
}

fragment float4 vt_cell_fragment(VTCellRaster v [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                 constant VTImageSample& tile [[buffer(0)]]) {
    if (tile.imageSize.x != 0) {
        uint2 pixel = uint2(clamp(floor(v.uv * float2(tile.imageSize)), float2(0), float2(tile.imageSize - 1)));
        if (any(pixel < tile.origin) || any(pixel >= tile.origin + tile.size)) discard_fragment();
        return atlas.read(pixel - tile.origin + tile.pageOrigin) * v.color;
    }
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    // Quantize the tinted coverage to 8-bit premultiplied, as CoreText
    // rasterizes colored text, so blending matches it exactly. Fills and
    // RGBA texels are already exact multiples of 1/255.
    return floor(atlas.sample(s, v.uv) * v.color * 255.0 + 0.001) / 255.0;
}

// MARK: - Cell background pass

struct VTBgUniforms {
    float2 paddingPx;  // grid origin in output pixels
    float2 cellPx;     // cell size in output pixels (integral per VTLayout)
    uint2  grid;       // columns, rows
};

struct VTBgRaster { float4 position [[position]]; };

vertex VTBgRaster vt_bg_vertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    return {float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1)};
}

// Every cell background in one fullscreen pass (ghostty's cell_bg_fragment):
// the fragment recovers its grid cell and reads a packed RGBA array. Alpha-0
// entries (default background) preserve what is already underneath.
fragment float4 vt_bg_fragment(VTBgRaster v [[stage_in]], constant VTBgUniforms& u [[buffer(0)]],
                               constant uchar4* cells [[buffer(1)]]) {
    int2 gp = int2(floor((v.position.xy - u.paddingPx) / u.cellPx));
    if (gp.x < 0 || gp.y < 0 || gp.x >= int(u.grid.x) || gp.y >= int(u.grid.y)) return float4(0);
    uchar4 c = cells[uint(gp.y) * u.grid.x + uint(gp.x)];
    return float4(float3(c.r, c.g, c.b) / 255.0, float(c.a) / 255.0);
}
