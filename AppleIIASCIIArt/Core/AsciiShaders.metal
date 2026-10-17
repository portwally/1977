//
//  AsciiShaders.metal
//
//  Metal compute shader that converts a source image into a grid of
//  luminance values (one byte per character cell). The mapping mirrors
//  the CPU `ASCIIConverter.convert(image:settings:)` pipeline:
//
//    1. Aspect-fill the source into the platform's native screen size.
//    2. Sample the center of each character cell.
//    3. Apply brightness offset + contrast factor in sRGB-encoded byte
//       space (255-scaled), matching the CPU code exactly so the output
//       is bit-identical to the CPU path.
//    4. Compute BT.709 luminance (0.2126 R + 0.7152 G + 0.0722 B).
//    5. Optionally invert.
//    6. Optionally flip horizontally / vertically — applied as a write-
//       coordinate transform so the output buffer is in display order
//       (no second pass needed).
//
//  Output buffer layout: row-major, `params.gridSize.x × params.gridSize.y`
//  bytes, value 0–255. The Swift side maps these into character-ramp
//  indices.
//

#include <metal_stdlib>
using namespace metal;

struct ConvertParams {
    uint2  gridSize;      // e.g. 40×24 (Apple II 40-col) or 80×24
    uint2  screenSize;    // platform native, e.g. 280×192
    uint2  sourceSize;    // source image dimensions (post-downsample to 320 max)
    float  brightness;    // pre-multiplied: settings.brightness * 255
    float  contrast;      // already-computed factor (>=0 ? 1+c*3 : 1+c)
    uint   invert;        // 0 / 1
    uint   flipH;         // 0 / 1
    uint   flipV;         // 0 / 1
};

kernel void convertToLuminance(
    texture2d<float, access::sample> source [[texture(0)]],
    device uchar                    *output [[buffer(0)]],
    constant ConvertParams          &params [[buffer(1)]],
    uint2                            gid    [[thread_position_in_grid]]
) {
    // Guard against threadgroup-rounding overflow.
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    // --- 1. Cell center in screen coordinates ---
    float cellW = float(params.screenSize.x) / float(params.gridSize.x);
    float cellH = float(params.screenSize.y) / float(params.gridSize.y);
    float cellX = (float(gid.x) + 0.5) * cellW;
    float cellY = (float(gid.y) + 0.5) * cellH;

    // --- 2. Aspect-fill: map screen coord → source coord ---
    float scaleX = float(params.screenSize.x) / float(params.sourceSize.x);
    float scaleY = float(params.screenSize.y) / float(params.sourceSize.y);
    float scale  = max(scaleX, scaleY);
    float scaledW = float(params.sourceSize.x) * scale;
    float scaledH = float(params.sourceSize.y) * scale;
    float offX = (float(params.screenSize.x) - scaledW) * 0.5;
    float offY = (float(params.screenSize.y) - scaledH) * 0.5;

    float srcX = (cellX - offX) / scale;
    float srcY = (cellY - offY) / scale;

    // Normalised UV for sampling.
    float2 uv = float2(srcX, srcY) / float2(params.sourceSize);

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = source.sample(s, uv);

    // --- 3. Brightness / contrast (matches CPU code byte-for-byte) ---
    float r = color.r * 255.0;
    float g = color.g * 255.0;
    float b = color.b * 255.0;

    r = clamp((r - 128.0) * params.contrast + 128.0 + params.brightness, 0.0, 255.0);
    g = clamp((g - 128.0) * params.contrast + 128.0 + params.brightness, 0.0, 255.0);
    b = clamp((b - 128.0) * params.contrast + 128.0 + params.brightness, 0.0, 255.0);

    // --- 4. BT.709 luminance ---
    float lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    // --- 5. Invert ---
    if (params.invert != 0u) { lum = 255.0 - lum; }

    // --- 6. Flip (applied to write coordinate) ---
    uint dstX = (params.flipH != 0u) ? (params.gridSize.x - 1u - gid.x) : gid.x;
    uint dstY = (params.flipV != 0u) ? (params.gridSize.y - 1u - gid.y) : gid.y;

    output[dstY * params.gridSize.x + dstX] = uchar(round(lum));
}

// =============================================================================
// LORES / Double-LORES quantization kernel
//
// Same source-sampling math as `convertToLuminance` (aspect-fill +
// brightness/contrast + flip) — but instead of computing a single
// luminance byte per cell, it picks the closest match from the 16-color
// Apple II LORES palette and writes that palette index (0–15) per cell.
//
// Output buffer: `gridSize.x × gridSize.y` bytes (typically 40 × 48 for
// LORES, 80 × 48 for DLORES). The Swift side packs two vertically-
// adjacent indices into one screen byte (low nibble = top, high = bottom)
// and writes that into the text-page layout.
// =============================================================================

constant float3 loresPalette[16] = {
    float3(  0,   0,   0) / 255.0,   // 0  Black
    float3(221,   0,  51) / 255.0,   // 1  Magenta
    float3(  0,   0, 153) / 255.0,   // 2  Dark Blue
    float3(221,   0, 221) / 255.0,   // 3  Purple
    float3(  0, 119,  34) / 255.0,   // 4  Dark Green
    float3( 85,  85,  85) / 255.0,   // 5  Gray (dark)
    float3( 34,  34, 255) / 255.0,   // 6  Medium Blue
    float3(102, 170, 255) / 255.0,   // 7  Light Blue
    float3(136,  85,   0) / 255.0,   // 8  Brown
    float3(255, 102,   0) / 255.0,   // 9  Orange
    float3(170, 170, 170) / 255.0,   // 10 Gray (light)
    float3(255, 153, 136) / 255.0,   // 11 Pink
    float3( 17, 221,   0) / 255.0,   // 12 Light Green
    float3(255, 255,   0) / 255.0,   // 13 Yellow
    float3( 68, 255, 170) / 255.0,   // 14 Aqua
    float3(255, 255, 255) / 255.0,   // 15 White
};

kernel void convertToLores(
    texture2d<float, access::sample> source [[texture(0)]],
    device uchar                    *output [[buffer(0)]],
    constant ConvertParams          &params [[buffer(1)]],
    uint2                            gid    [[thread_position_in_grid]]
) {
    if (gid.x >= params.gridSize.x || gid.y >= params.gridSize.y) { return; }

    // Aspect-fill: same as the luminance kernel.
    float cellW = float(params.screenSize.x) / float(params.gridSize.x);
    float cellH = float(params.screenSize.y) / float(params.gridSize.y);
    float cellX = (float(gid.x) + 0.5) * cellW;
    float cellY = (float(gid.y) + 0.5) * cellH;

    float scaleX = float(params.screenSize.x) / float(params.sourceSize.x);
    float scaleY = float(params.screenSize.y) / float(params.sourceSize.y);
    float scale  = max(scaleX, scaleY);
    float scaledW = float(params.sourceSize.x) * scale;
    float scaledH = float(params.sourceSize.y) * scale;
    float offX = (float(params.screenSize.x) - scaledW) * 0.5;
    float offY = (float(params.screenSize.y) - scaledH) * 0.5;

    float srcX = (cellX - offX) / scale;
    float srcY = (cellY - offY) / scale;
    float2 uv  = float2(srcX, srcY) / float2(params.sourceSize);

    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 color = source.sample(s, uv);

    // Brightness / contrast (byte-space, same as luminance kernel).
    float r = color.r * 255.0;
    float g = color.g * 255.0;
    float b = color.b * 255.0;
    r = clamp((r - 128.0) * params.contrast + 128.0 + params.brightness, 0.0, 255.0);
    g = clamp((g - 128.0) * params.contrast + 128.0 + params.brightness, 0.0, 255.0);
    b = clamp((b - 128.0) * params.contrast + 128.0 + params.brightness, 0.0, 255.0);

    // Invert: subtract from 255.
    if (params.invert != 0u) {
        r = 255.0 - r;
        g = 255.0 - g;
        b = 255.0 - b;
    }

    float3 src = float3(r, g, b) / 255.0;

    // Find closest palette index by Euclidean RGB distance.
    uint  bestIdx  = 0u;
    float bestDist = 1e30;
    for (uint i = 0u; i < 16u; ++i) {
        float3 d = src - loresPalette[i];
        float  dist = dot(d, d);
        if (dist < bestDist) { bestDist = dist; bestIdx = i; }
    }

    uint dstX = (params.flipH != 0u) ? (params.gridSize.x - 1u - gid.x) : gid.x;
    uint dstY = (params.flipV != 0u) ? (params.gridSize.y - 1u - gid.y) : gid.y;
    output[dstY * params.gridSize.x + dstX] = uchar(bestIdx);
}
