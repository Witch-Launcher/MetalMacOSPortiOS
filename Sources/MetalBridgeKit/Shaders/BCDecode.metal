// MetalBridge BC (BCN) decode kernels.
//
// macOS GPU family 1 advertises BC texture formats; Apple GPUs gained hardware
// sampling only with Apple7 (Metal Feature Set Tables: "BC texture compression -
// Metal 3 - Apple7"). Apps recompiled from macOS therefore hand the bridge BC data
// that A9 cannot sample. These kernels decode every BCn format into an ordinary
// rgba8Unorm / rgba8Snorm / rgba16Float staging buffer that Swift uploads with
// replaceRegion, so the app keeps its compressed assets and byte budgets.
//
// The decode logic is a faithful Metal port of bcdec v0.985 by Sergii "iOrange"
// Kudlai (MIT OR Unlicense; vendored at third_party/bcdec/bcdec.h), which is
// bit-exact against the published Microsoft BC specifications. Differential tests
// in the test target run bcdec on the CPU and compare GPU output texel by texel.
//
// MSL 1.x discipline: A9 is compiled with -std=ios-metal1.2, and the 1.2 offline
// compiler miscompiles DYNAMIC indexing into thread-address-space arrays (verified:
// a palette[idx] lookup silently returned the wrong subset). Every kernel here is
// therefore written without thread-space arrays: per-texel values are selected
// through scalar if-chain helpers and written straight to the output buffer.
// Dynamic indexing is allowed only into CONSTANT-address-space tables, which the
// differential suite exercises on every format.
//
// Kernel ABI (same for every format):
//   buffer(0): compressed blocks, device const uchar*, 8 or 16 bytes per block,
//              laid out as ((width+3)/4) * ((height+3)/4) blocks in row-major order
//   buffer(1): output pixels, device uchar4* (BC1-5, BC7) or device half4* (BC6H),
//              width pixels per row, row-major
//   buffer(2): BCParams { uint widthPixels; uint heightPixels; uint flags; }
// thread_position_in_grid.xy indexes the 4x4 block being decoded.
// Input dimensions must be multiples of 4 (Metal block formats require this).

struct BCParams {
    uint widthPixels;
    uint heightPixels;
    uint flags; // bit 0: source is signed (BC4/BC5 SNorm, BC6H SF16)
};

struct BCBitStream {
    ulong low;
    ulong high;
    uint pos; // absolute bit position; seek-reads (bc_read_bits_at) don't touch it
    ulong origLow;  // pristine first/second words of the block, for absolute seeks
    ulong origHigh; // (low/high get consumed by sequential reads)
};

static inline uint bc_read_bits(thread BCBitStream& s, uint numBits) {
    uint mask = (uint)((1ul << numBits) - 1ul);
    uint bits = (uint)(s.low & (ulong)mask);
    s.low >>= numBits;
    s.low |= (s.high & (ulong)mask) << (64ul - numBits);
    s.high >>= numBits;
    s.pos += numBits;
    return bits;
}

static inline uint bc_read_bit(thread BCBitStream& s) {
    return bc_read_bits(s, 1u);
}

// Random-access read at an absolute bit position (BC7 reads its colour indices
// with computed offsets so no per-texel storage is needed). Reads the PRISTINE
// block words, not the consumed stream state.
static inline uint bc_read_bits_at(thread const BCBitStream& s, uint pos, uint numBits) {
    if (numBits == 0u || pos >= 128u) {
        return 0u;
    }
    if (pos + numBits > 128u) {
        numBits = 128u - pos;
    }
    if (pos >= 64u) {
        ulong mask = (numBits >= 64ul) ? ~0ul : ((1ul << numBits) - 1ul);
        return (uint)((s.origHigh >> (pos - 64u)) & mask);
    }
    ulong mask = (1ul << numBits) - 1ul;
    uint lowPart = (uint)((s.origLow >> pos) & mask);
    if (pos + numBits <= 64u) {
        return lowPart;
    }
    uint highCount = pos + numBits - 64u;
    uint highPart = (uint)(s.origHigh & ((1ul << highCount) - 1ul));
    return lowPart | (highPart << (64u - pos));
}

// Reversed bits pulling, used by BC6H modes 13 and 14 (why? just why?).
static inline uint bc_read_bits_reversed(thread BCBitStream& s, uint numBits) {
    uint bits = bc_read_bits(s, numBits);
    uint result = 0u;
    while (numBits-- > 0u) {
        result <<= 1u;
        result |= (bits & 1u);
        bits >>= 1u;
    }
    return result;
}

static inline ulong bc_get_u64(const device uchar* p) {
    return (ulong)p[0] | ((ulong)p[1] << 8) | ((ulong)p[2] << 16) | ((ulong)p[3] << 24) |
           ((ulong)p[4] << 32) | ((ulong)p[5] << 40) | ((ulong)p[6] << 48) | ((ulong)p[7] << 56);
}

static inline uint bc_get_u32(const device uchar* p) {
    return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24);
}

static inline uint bc_get_u16(const device uchar* p) {
    return (uint)p[0] | ((uint)p[1] << 8);
}

// ---------------------------------------------------------------- scalar selection helpers
// The MSL 1.x-safe replacement for dynamic indexing into thread arrays.

static inline uint bc_pick4(uint a0, uint a1, uint a2, uint a3, uint idx) {
    if (idx == 0u) { return a0; }
    if (idx == 1u) { return a1; }
    if (idx == 2u) { return a2; }
    return a3;
}

static inline uchar bc_pick4u8(uchar a0, uchar a1, uchar a2, uchar a3, uint idx) {
    if (idx == 0u) { return a0; }
    if (idx == 1u) { return a1; }
    if (idx == 2u) { return a2; }
    return a3;
}

static inline int bc_pick8(int a0, int a1, int a2, int a3, int a4, int a5, int a6, int a7, uint idx) {
    if (idx == 0u) { return a0; }
    if (idx == 1u) { return a1; }
    if (idx == 2u) { return a2; }
    if (idx == 3u) { return a3; }
    if (idx == 4u) { return a4; }
    if (idx == 5u) { return a5; }
    if (idx == 6u) { return a6; }
    return a7;
}

// ---------------------------------------------------------------- BC1 color block (BC1 / BC2 / BC3)

// Decodes the 8-byte colour part of a block straight into the output buffer.
// onlyOpaqueMode forces the standard 4-ref-colour mode (BC3 requirement).
static inline void bc_decode_color(device uchar4* output,
                                   uint pitchPixels,
                                   uint texelBaseX,
                                   uint texelBaseY,
                                   const device uchar* block,
                                   bool onlyOpaqueMode) {
    uint c0 = bc_get_u16(block);
    uint c1 = bc_get_u16(block + 2);

    uint r0 = (c0 >> 11) & 0x1Fu;
    uint g0 = (c0 >> 5) & 0x3Fu;
    uint b0 = c0 & 0x1Fu;
    uint r1 = (c1 >> 11) & 0x1Fu;
    uint g1 = (c1 >> 5) & 0x3Fu;
    uint b1 = c1 & 0x1Fu;

    // Expand 565 to 888 with the exact rounding coefficients from the spec.
    uint3 ref0 = uint3((r0 * 527 + 23) >> 6, (g0 * 259 + 33) >> 6, (b0 * 527 + 23) >> 6);
    uint3 ref1 = uint3((r1 * 527 + 23) >> 6, (g1 * 259 + 33) >> 6, (b1 * 527 + 23) >> 6);
    uint3 ref2;
    uint3 ref3;
    uchar alpha0 = 255;
    uchar alpha1 = 255;
    uchar alpha2 = 255;
    uchar alpha3 = 255;

    if (c0 > c1 || onlyOpaqueMode) {
        // Standard BC1 mode (BC3 colour blocks always use this mode).
        ref2 = uint3(((2 * r0 + r1) * 351 + 61) >> 7,
                     ((2 * g0 + g1) * 2763 + 1039) >> 11,
                     ((2 * b0 + b1) * 351 + 61) >> 7);
        ref3 = uint3(((r0 + 2 * r1) * 351 + 61) >> 7,
                     ((g0 + 2 * g1) * 2763 + 1039) >> 11,
                     ((b0 + 2 * b1) * 351 + 61) >> 7);
    } else {
        // Rare BC1A mode: transparent.
        ref2 = uint3(((r0 + r1) * 1053 + 125) >> 8,
                     ((g0 + g1) * 4145 + 1019) >> 11,
                     ((b0 + b1) * 1053 + 125) >> 8);
        ref3 = uint3(0u);
        alpha3 = 0;
    }

    uint colorIndices = bc_get_u32(block + 4);
    for (uint row = 0; row < 4u; ++row) {
        for (uint col = 0; col < 4u; ++col) {
            uint idx = colorIndices & 3u;
            colorIndices >>= 2;
            output[(texelBaseY + row) * pitchPixels + texelBaseX + col] = uchar4(
                (uchar)bc_pick4(ref0.x, ref1.x, ref2.x, ref3.x, idx),
                (uchar)bc_pick4(ref0.y, ref1.y, ref2.y, ref3.y, idx),
                (uchar)bc_pick4(ref0.z, ref1.z, ref2.z, ref3.z, idx),
                bc_pick4u8(alpha0, alpha1, alpha2, alpha3, idx));
        }
    }
}

// Sharp alpha (BC2): 16 nibbles, each scaled to 0..255.
static inline void bc_write_sharp_alpha(device uchar4* output,
                                        uint pitchPixels,
                                        uint texelBaseX,
                                        uint texelBaseY,
                                        const device uchar* block) {
    for (uint row = 0; row < 4u; ++row) {
        uint alpha = bc_get_u16(block + row * 2u);
        for (uint col = 0; col < 4u; ++col) {
            uchar value = (uchar)(((alpha >> (4u * col)) & 0xFu) * 17u);
            output[(texelBaseY + row) * pitchPixels + texelBaseX + col].a = value;
        }
    }
}

// ---------------------------------------------------------------- BC1

kernel void mb_bc1_decode(const device uchar* blocks [[buffer(0)]],
                          device uchar4* output [[buffer(1)]],
                          constant BCParams& params [[buffer(2)]],
                          uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 8;
    bc_decode_color(output, params.widthPixels, blockCoord.x * 4u, blockCoord.y * 4u, block, false);
}

// ---------------------------------------------------------------- BC2

kernel void mb_bc2_decode(const device uchar* blocks [[buffer(0)]],
                          device uchar4* output [[buffer(1)]],
                          constant BCParams& params [[buffer(2)]],
                          uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 16;
    uint baseX = blockCoord.x * 4u;
    uint baseY = blockCoord.y * 4u;
    // BC2 stores the alpha block first and the color block second; the color
    // block always decodes in opaque mode (no 1-bit alpha encoding).
    bc_decode_color(output, params.widthPixels, baseX, baseY, block + 8, true);
    bc_write_sharp_alpha(output, params.widthPixels, baseX, baseY, block);
}

// ---------------------------------------------------------------- BC3

// Smooth alpha (BC3): 8 reference values, 3-bit indices. Plain integer division
// exactly as the spec and bcdec define it (BC4 below uses rounded fixed point).
static inline void bc_write_smooth_alpha(device uchar4* output,
                                         uint pitchPixels,
                                         uint texelBaseX,
                                         uint texelBaseY,
                                         const device uchar* block) {
    ulong blockBits = bc_get_u64(block);
    int a0 = (int)(blockBits & 0xFFul);
    int a1 = (int)((blockBits >> 8) & 0xFFul);

    int a2;
    int a3;
    int a4;
    int a5;
    int a6;
    int a7;
    if (a0 > a1) {
        // 6 interpolated alpha values.
        a2 = (6 * a0 + a1) / 7;
        a3 = (5 * a0 + 2 * a1) / 7;
        a4 = (4 * a0 + 3 * a1) / 7;
        a5 = (3 * a0 + 4 * a1) / 7;
        a6 = (2 * a0 + 5 * a1) / 7;
        a7 = (a0 + 6 * a1) / 7;
    } else {
        // 4 interpolated alpha values.
        a2 = (4 * a0 + a1) / 5;
        a3 = (3 * a0 + 2 * a1) / 5;
        a4 = (2 * a0 + 3 * a1) / 5;
        a5 = (a0 + 4 * a1) / 5;
        a6 = 0;
        a7 = 255;
    }

    ulong indices = blockBits >> 16;
    for (uint row = 0; row < 4u; ++row) {
        for (uint col = 0; col < 4u; ++col) {
            int value = bc_pick8(a0, a1, a2, a3, a4, a5, a6, a7, (uint)(indices & 0x7ul));
            indices >>= 3;
            output[(texelBaseY + row) * pitchPixels + texelBaseX + col].a = (uchar)value;
        }
    }
}

kernel void mb_bc3_decode(const device uchar* blocks [[buffer(0)]],
                          device uchar4* output [[buffer(1)]],
                          constant BCParams& params [[buffer(2)]],
                          uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 16;
    uint baseX = blockCoord.x * 4u;
    uint baseY = blockCoord.y * 4u;
    // BC3 also stores the alpha block first and the color block second.
    bc_decode_color(output, params.widthPixels, baseX, baseY, block + 8, true);
    bc_write_smooth_alpha(output, params.widthPixels, baseX, baseY, block);
}

// ---------------------------------------------------------------- BC4 / BC5 (precise, signed-aware)

struct BC4Palette {
    int a0;
    int a1;
    int a2;
    int a3;
    int a4;
    int a5;
    int a6;
    int a7;
    ulong indices;
};

static inline BC4Palette bc_bc4_palette(const device uchar* block, bool signedMode) {
    BC4Palette p;
    ulong blockBits = bc_get_u64(block);
    if (signedMode) {
        p.a0 = (int)(char)(uchar)(blockBits & 0xFFul);
        p.a1 = (int)(char)(uchar)((blockBits >> 8) & 0xFFul);
        if (p.a0 < -127) { p.a0 = -127; } // -128 clamps to -127
        if (p.a1 < -127) { p.a1 = -127; }
    } else {
        p.a0 = (int)(blockBits & 0xFFul);
        p.a1 = (int)((blockBits >> 8) & 0xFFul);
    }

    // Fixed-point 16-bit weights from the D3D spec (0.2, 0.4, 0.6, 0.8 and 1/7 steps).
    if (p.a0 > p.a1) {
        p.a2 = (56173 * p.a0 + 9363 * p.a1 + 32768) >> 16;
        p.a3 = (46812 * p.a0 + 18724 * p.a1 + 32768) >> 16;
        p.a4 = (37450 * p.a0 + 28086 * p.a1 + 32768) >> 16;
        p.a5 = (28086 * p.a0 + 37450 * p.a1 + 32768) >> 16;
        p.a6 = (18724 * p.a0 + 46812 * p.a1 + 32768) >> 16;
        p.a7 = (9363 * p.a0 + 56173 * p.a1 + 32768) >> 16;
    } else {
        p.a2 = (52429 * p.a0 + 13107 * p.a1 + 32768) >> 16;
        p.a3 = (39321 * p.a0 + 26215 * p.a1 + 32768) >> 16;
        p.a4 = (26215 * p.a0 + 39321 * p.a1 + 32768) >> 16;
        p.a5 = (13107 * p.a0 + 52429 * p.a1 + 32768) >> 16;
        p.a6 = signedMode ? -127 : 0;
        p.a7 = signedMode ? 127 : 255;
    }
    p.indices = blockBits >> 16;
    return p;
}

static inline uchar bc_bc4_texel_value(thread const BC4Palette& p, uint texel) {
    int value = bc_pick8(p.a0, p.a1, p.a2, p.a3, p.a4, p.a5, p.a6, p.a7,
                         (uint)((p.indices >> (3u * texel)) & 0x7ul));
    // rgba8Snorm wants the raw two's-complement byte; bcdec writes the same.
    return (uchar)value;
}

kernel void mb_bc4_decode(const device uchar* blocks [[buffer(0)]],
                          device uchar4* output [[buffer(1)]],
                          constant BCParams& params [[buffer(2)]],
                          uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 8;
    bool signedMode = (params.flags & 1u) != 0u;
    BC4Palette palette = bc_bc4_palette(block, signedMode);
    uint baseX = blockCoord.x * 4u;
    uint baseY = blockCoord.y * 4u;
    for (uint row = 0; row < 4u; ++row) {
        for (uint col = 0; col < 4u; ++col) {
            uint texel = row * 4u + col;
            uchar value = bc_bc4_texel_value(palette, texel);
            output[(baseY + row) * params.widthPixels + baseX + col] = uchar4(value, value, value, 255);
        }
    }
}

kernel void mb_bc5_decode(const device uchar* blocks [[buffer(0)]],
                          device uchar4* output [[buffer(1)]],
                          constant BCParams& params [[buffer(2)]],
                          uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 16;
    bool signedMode = (params.flags & 1u) != 0u;
    BC4Palette rPalette = bc_bc4_palette(block, signedMode);
    BC4Palette gPalette = bc_bc4_palette(block + 8, signedMode);
    uint baseX = blockCoord.x * 4u;
    uint baseY = blockCoord.y * 4u;
    for (uint row = 0; row < 4u; ++row) {
        for (uint col = 0; col < 4u; ++col) {
            uint texel = row * 4u + col;
            output[(baseY + row) * params.widthPixels + baseX + col] =
                uchar4(bc_bc4_texel_value(rPalette, texel), bc_bc4_texel_value(gPalette, texel), 0, 255);
        }
    }
}
constant uchar mb_bc7_partition_sets[2][64][4][4] = {
    {   // 2-subset partitions; MSB (0x80) marks the fix-up texel of subset 1
        { {128, 0,   1, 1}, {0, 0,   1, 1}, {  0, 0, 1, 1}, {0, 0, 1, 129} }, /*  0 */
        { {128, 0,   0, 1}, {0, 0,   0, 1}, {  0, 0, 0, 1}, {0, 0, 0, 129} }, /*  1 */
        { {128, 1,   1, 1}, {0, 1,   1, 1}, {  0, 1, 1, 1}, {0, 1, 1, 129} }, /*  2 */
        { {128, 0,   0, 1}, {0, 0,   1, 1}, {  0, 0, 1, 1}, {0, 1, 1, 129} }, /*  3 */
        { {128, 0,   0, 0}, {0, 0,   0, 1}, {  0, 0, 0, 1}, {0, 0, 1, 129} }, /*  4 */
        { {128, 0,   1, 1}, {0, 1,   1, 1}, {  0, 1, 1, 1}, {1, 1, 1, 129} }, /*  5 */
        { {128, 0,   0, 1}, {0, 0,   1, 1}, {  0, 1, 1, 1}, {1, 1, 1, 129} }, /*  6 */
        { {128, 0,   0, 0}, {0, 0,   0, 1}, {  0, 0, 1, 1}, {0, 1, 1, 129} }, /*  7 */
        { {128, 0,   0, 0}, {0, 0,   0, 0}, {  0, 0, 0, 1}, {0, 0, 1, 129} }, /*  8 */
        { {128, 0,   1, 1}, {0, 1,   1, 1}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /*  9 */
        { {128, 0,   0, 0}, {0, 0,   0, 1}, {  0, 1, 1, 1}, {1, 1, 1, 129} }, /* 10 */
        { {128, 0,   0, 0}, {0, 0,   0, 0}, {  0, 0, 0, 1}, {0, 1, 1, 129} }, /* 11 */
        { {128, 0,   0, 1}, {0, 1,   1, 1}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /* 12 */
        { {128, 0,   0, 0}, {0, 0,   0, 0}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /* 13 */
        { {128, 0,   0, 0}, {1, 1,   1, 1}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /* 14 */
        { {128, 0,   0, 0}, {0, 0,   0, 0}, {  0, 0, 0, 0}, {1, 1, 1, 129} }, /* 15 */
        { {128, 0,   0, 0}, {1, 0,   0, 0}, {  1, 1, 1, 0}, {1, 1, 1, 129} }, /* 16 */
        { {128, 1, 129, 1}, {0, 0,   0, 1}, {  0, 0, 0, 0}, {0, 0, 0,   0} }, /* 17 */
        { {128, 0,   0, 0}, {0, 0,   0, 0}, {129, 0, 0, 0}, {1, 1, 1,   0} }, /* 18 */
        { {128, 1, 129, 1}, {0, 0,   1, 1}, {  0, 0, 0, 1}, {0, 0, 0,   0} }, /* 19 */
        { {128, 0, 129, 1}, {0, 0,   0, 1}, {  0, 0, 0, 0}, {0, 0, 0,   0} }, /* 20 */
        { {128, 0,   0, 0}, {1, 0,   0, 0}, {129, 1, 0, 0}, {1, 1, 1,   0} }, /* 21 */
        { {128, 0,   0, 0}, {0, 0,   0, 0}, {129, 0, 0, 0}, {1, 1, 0,   0} }, /* 22 */
        { {128, 1,   1, 1}, {0, 0,   1, 1}, {  0, 0, 1, 1}, {0, 0, 0, 129} }, /* 23 */
        { {128, 0, 129, 1}, {0, 0,   0, 1}, {  0, 0, 0, 1}, {0, 0, 0,   0} }, /* 24 */
        { {128, 0,   0, 0}, {1, 0,   0, 0}, {129, 0, 0, 0}, {1, 1, 0,   0} }, /* 25 */
        { {128, 1, 129, 0}, {0, 1,   1, 0}, {  0, 1, 1, 0}, {0, 1, 1,   0} }, /* 26 */
        { {128, 0, 129, 1}, {0, 1,   1, 0}, {  0, 1, 1, 0}, {1, 1, 0,   0} }, /* 27 */
        { {128, 0,   0, 1}, {0, 1,   1, 1}, {129, 1, 1, 0}, {1, 0, 0,   0} }, /* 28 */
        { {128, 0,   0, 0}, {1, 1,   1, 1}, {129, 1, 1, 1}, {0, 0, 0,   0} }, /* 29 */
        { {128, 1, 129, 1}, {0, 0,   0, 1}, {  1, 0, 0, 0}, {1, 1, 1,   0} }, /* 30 */
        { {128, 0, 129, 1}, {1, 0,   0, 1}, {  1, 0, 0, 1}, {1, 1, 0,   0} }, /* 31 */
        { {128, 1,   0, 1}, {0, 1,   0, 1}, {  0, 1, 0, 1}, {0, 1, 0, 129} }, /* 32 */
        { {128, 0,   0, 0}, {1, 1,   1, 1}, {  0, 0, 0, 0}, {1, 1, 1, 129} }, /* 33 */
        { {128, 1,   0, 1}, {1, 0, 129, 0}, {  0, 1, 0, 1}, {1, 0, 1,   0} }, /* 34 */
        { {128, 0,   1, 1}, {0, 0,   1, 1}, {129, 1, 0, 0}, {1, 1, 0,   0} }, /* 35 */
        { {128, 0, 129, 1}, {1, 1,   0, 0}, {  0, 0, 1, 1}, {1, 1, 0,   0} }, /* 36 */
        { {128, 1,   0, 1}, {0, 1,   0, 1}, {129, 0, 1, 0}, {1, 0, 1,   0} }, /* 37 */
        { {128, 1,   1, 0}, {1, 0,   0, 1}, {  0, 1, 1, 0}, {1, 0, 0, 129} }, /* 38 */
        { {128, 1,   0, 1}, {1, 0,   1, 0}, {  1, 0, 1, 0}, {0, 1, 0, 129} }, /* 39 */
        { {128, 1, 129, 1}, {0, 0,   1, 1}, {  1, 1, 0, 0}, {1, 1, 1,   0} }, /* 40 */
        { {128, 0,   0, 1}, {0, 0,   1, 1}, {129, 1, 0, 0}, {1, 0, 0,   0} }, /* 41 */
        { {128, 0, 129, 1}, {0, 0,   1, 0}, {  0, 1, 0, 0}, {1, 1, 0,   0} }, /* 42 */
        { {128, 0, 129, 1}, {1, 0,   1, 1}, {  1, 1, 0, 1}, {1, 1, 0,   0} }, /* 43 */
        { {128, 1, 129, 0}, {1, 0,   0, 1}, {  1, 0, 0, 1}, {0, 1, 1,   0} }, /* 44 */
        { {128, 0,   1, 1}, {1, 1,   0, 0}, {  1, 1, 0, 0}, {0, 0, 1, 129} }, /* 45 */
        { {128, 1,   1, 0}, {0, 1,   1, 0}, {  1, 0, 0, 1}, {1, 0, 0, 129} }, /* 46 */
        { {128, 0,   0, 0}, {0, 1, 129, 0}, {  0, 1, 1, 0}, {0, 0, 0,   0} }, /* 47 */
        { {128, 1,   0, 0}, {1, 1, 129, 0}, {  0, 1, 0, 0}, {0, 0, 0,   0} }, /* 48 */
        { {128, 0, 129, 0}, {0, 1,   1, 1}, {  0, 0, 1, 0}, {0, 0, 0,   0} }, /* 49 */
        { {128, 0,   0, 0}, {0, 0, 129, 0}, {  0, 1, 1, 1}, {0, 0, 1,   0} }, /* 50 */
        { {128, 0,   0, 0}, {0, 1,   0, 0}, {129, 1, 1, 0}, {0, 1, 0,   0} }, /* 51 */
        { {128, 1,   1, 0}, {1, 1,   0, 0}, {  1, 0, 0, 1}, {0, 0, 1, 129} }, /* 52 */
        { {128, 0,   1, 1}, {0, 1,   1, 0}, {  1, 1, 0, 0}, {1, 0, 0, 129} }, /* 53 */
        { {128, 1, 129, 0}, {0, 0,   1, 1}, {  1, 0, 0, 1}, {1, 1, 0,   0} }, /* 54 */
        { {128, 0, 129, 1}, {1, 0,   0, 1}, {  1, 1, 0, 0}, {0, 1, 1,   0} }, /* 55 */
        { {128, 1,   1, 0}, {1, 1,   0, 0}, {  1, 1, 0, 0}, {1, 0, 0, 129} }, /* 56 */
        { {128, 1,   1, 0}, {0, 0,   1, 1}, {  0, 0, 1, 1}, {1, 0, 0, 129} }, /* 57 */
        { {128, 1,   1, 1}, {1, 1,   1, 0}, {  1, 0, 0, 0}, {0, 0, 0, 129} }, /* 58 */
        { {128, 0,   0, 1}, {1, 0,   0, 0}, {  1, 1, 1, 0}, {0, 1, 1, 129} }, /* 59 */
        { {128, 0,   0, 0}, {1, 1,   1, 1}, {  0, 0, 1, 1}, {0, 0, 1, 129} }, /* 60 */
        { {128, 0, 129, 1}, {0, 0,   1, 1}, {  1, 1, 1, 1}, {0, 0, 0,   0} }, /* 61 */
        { {128, 0, 129, 0}, {0, 0,   1, 0}, {  1, 1, 1, 0}, {1, 1, 1,   0} }, /* 62 */
        { {128, 1,   0, 0}, {0, 1,   0, 0}, {  0, 1, 1, 1}, {0, 1, 1, 129} }  /* 63 */
    },
    {   // 3-subset partitions; 0x80 marks the subset-1 fix-up, 0x81..0x82 mark subset 2
        { {128, 0, 1, 129}, {0,   0,   1, 1}, {  0,   2,   2, 1}, {  2,   2, 2, 130} }, /*  0 */
        { {128, 0, 0, 129}, {0,   0,   1, 1}, {130,   2,   1, 1}, {  2,   2, 2,   1} }, /*  1 */
        { {128, 0, 0,   0}, {2,   0,   0, 1}, {130,   2,   1, 1}, {  2,   2, 1, 129} }, /*  2 */
        { {128, 2, 2, 130}, {0,   0,   2, 2}, {  0,   0,   1, 1}, {  0,   1, 1, 129} }, /*  3 */
        { {128, 0, 0,   0}, {0,   0,   0, 0}, {129,   1,   2, 2}, {  1,   1, 2, 130} }, /*  4 */
        { {128, 0, 1, 129}, {0,   0,   1, 1}, {  0,   0,   2, 2}, {  0,   0, 2, 130} }, /*  5 */
        { {128, 0, 2, 130}, {0,   0,   2, 2}, {  1,   1,   1, 1}, {  1,   1, 1, 129} }, /*  6 */
        { {128, 0, 1,   1}, {0,   0,   1, 1}, {130,   2,   1, 1}, {  2,   2, 1, 129} }, /*  7 */
        { {128, 0, 0,   0}, {0,   0,   0, 0}, {129,   1,   1, 1}, {  2,   2, 2, 130} }, /*  8 */
        { {128, 0, 0,   0}, {1,   1,   1, 1}, {129,   1,   1, 1}, {  2,   2, 2, 130} }, /*  9 */
        { {128, 0, 0,   0}, {1,   1, 129, 1}, {  2,   2,   2, 2}, {  2,   2, 2, 130} }, /* 10 */
        { {128, 0, 1,   2}, {0,   0, 129, 2}, {  0,   0,   1, 2}, {  0,   0, 1, 130} }, /* 11 */
        { {128, 1, 1,   2}, {0,   1, 129, 2}, {  0,   1,   1, 2}, {  0,   1, 1, 130} }, /* 12 */
        { {128, 1, 2,   2}, {0, 129,   2, 2}, {  0,   1,   2, 2}, {  0,   1, 2, 130} }, /* 13 */
        { {128, 0, 1, 129}, {0,   1,   1, 2}, {  1,   1,   2, 2}, {  1,   2, 2, 130} }, /* 14 */
        { {128, 0, 1, 129}, {2,   0,   0, 1}, {130,   2,   0, 0}, {  2,   2, 2,   0} }, /* 15 */
        { {128, 0, 0, 129}, {0,   0,   1, 1}, {  0,   1,   1, 2}, {  1,   1, 2, 130} }, /* 16 */
        { {128, 1, 1, 129}, {0,   0,   1, 1}, {130,   0,   0, 1}, {  2,   2, 0,   0} }, /* 17 */
        { {128, 0, 0,   0}, {1,   1,   2, 2}, {129,   1,   2, 2}, {  1,   1, 2, 130} }, /* 18 */
        { {128, 0, 2, 130}, {0,   0,   2, 2}, {  0,   0,   2, 2}, {  1,   1, 1, 129} }, /* 19 */
        { {128, 1, 1, 129}, {0,   1,   1, 1}, {  0,   2,   2, 2}, {  0,   2, 2, 130} }, /* 20 */
        { {128, 0, 0, 129}, {0,   0,   0, 1}, {130,   2,   2, 1}, {  2,   2, 2,   1} }, /* 21 */
        { {128, 0, 0,   0}, {0,   0, 129, 1}, {  0,   1,   2, 2}, {  0,   1, 2, 130} }, /* 22 */
        { {128, 0, 0,   0}, {1,   1,   0, 0}, {130,   2, 129, 0}, {  2,   2, 1,   0} }, /* 23 */
        { {128, 1, 2, 130}, {0, 129,   2, 2}, {  0,   0,   1, 1}, {  0,   0, 0,   0} }, /* 24 */
        { {128, 0, 1,   2}, {0,   0,   1, 2}, {129,   1,   2, 2}, {  2,   2, 2, 130} }, /* 25 */
        { {128, 1, 1,   0}, {1,   2, 130, 1}, {129,   2,   2, 1}, {  0,   1, 1,   0} }, /* 26 */
        { {128, 0, 0,   0}, {0,   1, 129, 0}, {  1,   2, 130, 1}, {  1,   2, 2,   1} }, /* 27 */
        { {128, 0, 2,   2}, {1,   1,   0, 2}, {129,   1,   0, 2}, {  0,   0, 2, 130} }, /* 28 */
        { {128, 1, 1,   0}, {0, 129,   1, 0}, {  2,   0,   0, 2}, {  2,   2, 2, 130} }, /* 29 */
        { {128, 0, 1,   1}, {0,   1,   2, 2}, {  0,   1, 130, 2}, {  0,   0, 1, 129} }, /* 30 */
        { {128, 0, 0,   0}, {2,   0,   0, 0}, {130,   2,   1, 1}, {  2,   2, 2, 129} }, /* 31 */
        { {128, 0, 0,   0}, {0,   0,   0, 2}, {129,   1,   2, 2}, {  1,   2, 2, 130} }, /* 32 */
        { {128, 2, 2, 130}, {0,   0,   2, 2}, {  0,   0,   1, 2}, {  0,   0, 1, 129} }, /* 33 */
        { {128, 0, 1, 129}, {0,   0,   1, 2}, {  0,   0,   2, 2}, {  0,   2, 2, 130} }, /* 34 */
        { {128, 1, 2,   0}, {0, 129,   2, 0}, {  0,   1, 130, 0}, {  0,   1, 2,   0} }, /* 35 */
        { {128, 0, 0,   0}, {1,   1, 129, 1}, {  2,   2, 130, 2}, {  0,   0, 0,   0} }, /* 36 */
        { {128, 1, 2,   0}, {1,   2,   0, 1}, {130,   0, 129, 2}, {  0,   1, 2,   0} }, /* 37 */
        { {128, 1, 2,   0}, {2,   0,   1, 2}, {129, 130,   0, 1}, {  0,   1, 2,   0} }, /* 38 */
        { {128, 0, 1,   1}, {2,   2,   0, 0}, {  1,   1, 130, 2}, {  0,   0, 1, 129} }, /* 39 */
        { {128, 0, 1,   1}, {1,   1, 130, 2}, {  2,   2,   0, 0}, {  0,   0, 1, 129} }, /* 40 */
        { {128, 1, 0, 129}, {0,   1,   0, 1}, {  2,   2,   2, 2}, {  2,   2, 2, 130} }, /* 41 */
        { {128, 0, 0,   0}, {0,   0,   0, 0}, {130,   1,   2, 1}, {  2,   1, 2, 129} }, /* 42 */
        { {128, 0, 2,   2}, {1, 129,   2, 2}, {  0,   0,   2, 2}, {  1,   1, 2, 130} }, /* 43 */
        { {128, 0, 2, 130}, {0,   0,   1, 1}, {  0,   0,   2, 2}, {  0,   0, 1, 129} }, /* 44 */
        { {128, 2, 2,   0}, {1,   2, 130, 1}, {  0,   2,   2, 0}, {  1,   2, 2, 129} }, /* 45 */
        { {128, 1, 0,   1}, {2,   2, 130, 2}, {  2,   2,   2, 2}, {  0,   1, 0, 129} }, /* 46 */
        { {128, 0, 0,   0}, {2,   1,   2, 1}, {130,   1,   2, 1}, {  2,   1, 2, 129} }, /* 47 */
        { {128, 1, 0, 129}, {0,   1,   0, 1}, {  0,   1,   0, 1}, {  2,   2, 2, 130} }, /* 48 */
        { {128, 2, 2, 130}, {0,   1,   1, 1}, {  0,   2,   2, 2}, {  0,   1, 1, 129} }, /* 49 */
        { {128, 0, 0,   2}, {1, 129,   1, 2}, {  0,   0,   0, 2}, {  1,   1, 1, 130} }, /* 50 */
        { {128, 0, 0,   0}, {2, 129,   1, 2}, {  2,   1,   1, 2}, {  2,   1, 1, 130} }, /* 51 */
        { {128, 2, 2,   2}, {0, 129,   1, 1}, {  0,   1,   1, 1}, {  0,   2, 2, 130} }, /* 52 */
        { {128, 0, 0,   2}, {1,   1,   1, 2}, {129,   1,   1, 2}, {  0,   0, 0, 130} }, /* 53 */
        { {128, 1, 1,   0}, {0, 129,   1, 0}, {  0,   1,   1, 0}, {  2,   2, 2, 130} }, /* 54 */
        { {128, 0, 0,   0}, {0,   0,   0, 0}, {  2,   1, 129, 2}, {  2,   1, 1, 130} }, /* 55 */
        { {128, 1, 1,   0}, {0, 129,   1, 0}, {  2,   2,   2, 2}, {  2,   2, 2, 130} }, /* 56 */
        { {128, 0, 2,   2}, {0,   0,   1, 1}, {  0,   0, 129, 1}, {  0,   0, 2, 130} }, /* 57 */
        { {128, 0, 2,   2}, {1,   1,   2, 2}, {129,   1,   2, 2}, {  0,   0, 2, 130} }, /* 58 */
        { {128, 0, 0,   0}, {0,   0,   0, 0}, {  0,   0,   0, 0}, {  2, 129, 1, 130} }, /* 59 */
        { {128, 0, 0, 130}, {0,   0,   0, 1}, {  0,   0,   0, 2}, {  0,   0, 0, 129} }, /* 60 */
        { {128, 2, 2,   2}, {1,   2,   2, 2}, {  0,   2,   2, 2}, {129,   2, 2, 130} }, /* 61 */
        { {128, 1, 0, 129}, {2,   2,   2, 2}, {  2,   2,   2, 2}, {  2,   2, 2, 130} }, /* 62 */
        { {128, 1, 1, 129}, {2,   0,   1, 1}, {130,   2,   0, 1}, {  2,   2, 2,   0} }  /* 63 */
    }
};

constant uchar mb_bc7_actual_bits[2][8] = {
    { 4, 6, 5, 7, 5, 7, 7, 5 },     // RGB precision per mode
    { 0, 0, 0, 0, 6, 8, 7, 5 }      // A precision per mode
};

// Interpolation weights on the 0..64 scale, from the published specifications.
constant int mb_aWeight2[4] = { 0, 21, 43, 64 };
constant int mb_aWeight3[8] = { 0, 9, 18, 27, 37, 46, 55, 64 };
constant int mb_aWeight4[16] = { 0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64 };

static inline int bc_bc7_interpolate(int a, int b, int weight) {
    if (weight == 0) { return a; }
    if (weight == 64) { return b; }
    return (a * (64 - weight) + b * weight + 32) >> 6;
}

// Weight lookup through scalar branches (MSL 1.x: no dynamic thread-array indexing).
static inline int bc_bc7_weight(int indexBits, int index) {
    if (indexBits == 2) { return mb_aWeight2[index]; }
    if (indexBits == 3) { return mb_aWeight3[index]; }
    return mb_aWeight4[index];
}

// Precision expansion, exactly like bcdec: left-shift so the MSB sits in bit 7,
// then replicate the MSB of the ALREADY-SHIFTED value down into the revealed
// low bits (two sequential steps, not one fused expression).
static inline uint4 bc_bc7_expand(uint4 e, uint precRGB, uint precA) {
    e.x = e.x << (8u - precRGB);
    e.x |= e.x >> precRGB;
    e.y = e.y << (8u - precRGB);
    e.y |= e.y >> precRGB;
    e.z = e.z << (8u - precRGB);
    e.z |= e.z >> precRGB;
    e.w = e.w << (8u - precA);
    e.w |= e.w >> precA;
    return e;
}

static inline uint4 bc_bc7_ep(uint4 e0, uint4 e1, uint4 e2, uint4 e3, uint4 e4, uint4 e5, uint endpoint) {
    if (endpoint == 0u) { return e0; }
    if (endpoint == 1u) { return e1; }
    if (endpoint == 2u) { return e2; }
    if (endpoint == 3u) { return e3; }
    if (endpoint == 4u) { return e4; }
    return e5;
}

// Partition value for one texel: subset in the low bits, 0x80 = fix-up texel.
// Both tables live in constant space, which MSL 1.x indexes dynamically without
// the miscompiles that hit thread-space arrays.
static inline uint bc_bc7_partition_value(int numPartitions, int partition, int row, int col, uint texel) {
    if (numPartitions == 1) {
        // Single subset: texel 0 carries the fix-up marker.
        return (texel == 0u) ? 0x80u : 0u;
    }
    if (numPartitions == 2) {
        return (uint)mb_bc7_partition_sets[0][partition][row][col];
    }
    return (uint)mb_bc7_partition_sets[1][partition][row][col];
}

kernel void mb_bc7_decode(const device uchar* blocks [[buffer(0)]],
                          device uchar4* output [[buffer(1)]],
                          constant BCParams& params [[buffer(2)]],
                          uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 16;

    BCBitStream bstream;
    bstream.low = bc_get_u64(block);
    bstream.high = bc_get_u64(block + 8);
    bstream.pos = 0u;
    bstream.origLow = bstream.low;
    bstream.origHigh = bstream.high;

    int mode;
    for (mode = 0; mode < 8 && (0 == bc_read_bit(bstream)); ++mode) { }
    if (mode >= 8) {
        // Reserved mode: transparent black.
        uint base = blockCoord.y * 4u * params.widthPixels + blockCoord.x * 4u;
        for (uint row = 0; row < 4u; ++row) {
            for (uint col = 0; col < 4u; ++col) {
                output[base + row * params.widthPixels + col] = uchar4(0);
            }
        }
        return;
    }

    int partition = 0;
    int numPartitions = 1;
    int rotation = 0;
    int indexSelectionBit = 0;

    if (mode == 0 || mode == 1 || mode == 2 || mode == 3 || mode == 7) {
        numPartitions = (mode == 0 || mode == 2) ? 3 : 2;
        partition = (int)bc_read_bits(bstream, (mode == 0) ? 4u : 6u);
    }

    int numEndpoints = numPartitions * 2;

    if (mode == 4 || mode == 5) {
        rotation = (int)bc_read_bits(bstream, 2);
        if (mode == 4) {
            indexSelectionBit = (int)bc_read_bit(bstream);
        }
    }

    // Extract endpoints, channel-major exactly like bcdec: all R, then G, then B,
    // then alpha when the mode carries one.
    uint bitsRGB = (uint)mb_bc7_actual_bits[0][mode];
    uint bitsAlpha = (uint)mb_bc7_actual_bits[1][mode];
    int er0 = (int)bc_read_bits(bstream, bitsRGB);
    int er1 = (int)bc_read_bits(bstream, bitsRGB);
    int er2 = 0;
    int er3 = 0;
    int er4 = 0;
    int er5 = 0;
    if (numEndpoints > 2) {
        er2 = (int)bc_read_bits(bstream, bitsRGB);
        er3 = (int)bc_read_bits(bstream, bitsRGB);
    }
    if (numEndpoints > 4) {
        er4 = (int)bc_read_bits(bstream, bitsRGB);
        er5 = (int)bc_read_bits(bstream, bitsRGB);
    }

    int eg0 = (int)bc_read_bits(bstream, bitsRGB);
    int eg1 = (int)bc_read_bits(bstream, bitsRGB);
    int eg2 = 0;
    int eg3 = 0;
    int eg4 = 0;
    int eg5 = 0;
    if (numEndpoints > 2) {
        eg2 = (int)bc_read_bits(bstream, bitsRGB);
        eg3 = (int)bc_read_bits(bstream, bitsRGB);
    }
    if (numEndpoints > 4) {
        eg4 = (int)bc_read_bits(bstream, bitsRGB);
        eg5 = (int)bc_read_bits(bstream, bitsRGB);
    }

    int eb0 = (int)bc_read_bits(bstream, bitsRGB);
    int eb1 = (int)bc_read_bits(bstream, bitsRGB);
    int eb2 = 0;
    int eb3 = 0;
    int eb4 = 0;
    int eb5 = 0;
    if (numEndpoints > 2) {
        eb2 = (int)bc_read_bits(bstream, bitsRGB);
        eb3 = (int)bc_read_bits(bstream, bitsRGB);
    }
    if (numEndpoints > 4) {
        eb4 = (int)bc_read_bits(bstream, bitsRGB);
        eb5 = (int)bc_read_bits(bstream, bitsRGB);
    }

    int ea0 = 0;
    int ea1 = 0;
    int ea2 = 0;
    int ea3 = 0;
    int ea4 = 0;
    int ea5 = 0;
    if (bitsAlpha > 0u) {
        ea0 = (int)bc_read_bits(bstream, bitsAlpha);
        ea1 = (int)bc_read_bits(bstream, bitsAlpha);
        if (numEndpoints > 2) {
            ea2 = (int)bc_read_bits(bstream, bitsAlpha);
            ea3 = (int)bc_read_bits(bstream, bitsAlpha);
        }
        if (numEndpoints > 4) {
            ea4 = (int)bc_read_bits(bstream, bitsAlpha);
            ea5 = (int)bc_read_bits(bstream, bitsAlpha);
        }
    }

    // Fully decode endpoints: P-bits (modes 0, 1, 3, 6, 7), then precision expansion.
    uint pbitFlag = (mode == 0 || mode == 1 || mode == 3 || mode == 6 || mode == 7) ? 1u : 0u;
    uint4 e0 = uint4((uint)er0, (uint)eg0, (uint)eb0, (uint)ea0);
    uint4 e1 = uint4((uint)er1, (uint)eg1, (uint)eb1, (uint)ea1);
    uint4 e2 = uint4((uint)er2, (uint)eg2, (uint)eb2, (uint)ea2);
    uint4 e3 = uint4((uint)er3, (uint)eg3, (uint)eb3, (uint)ea3);
    uint4 e4 = uint4((uint)er4, (uint)eg4, (uint)eb4, (uint)ea4);
    uint4 e5 = uint4((uint)er5, (uint)eg5, (uint)eb5, (uint)ea5);
    if (pbitFlag != 0u) {
        e0 = e0 << 1u;
        e1 = e1 << 1u;
        e2 = e2 << 1u;
        e3 = e3 << 1u;
        e4 = e4 << 1u;
        e5 = e5 << 1u;
        if (mode == 1) {
            // Shared P-bits: one for the endpoint pair (0,1), one for (2,3); RGB only.
            uint pa = bc_read_bit(bstream);
            uint pb = bc_read_bit(bstream);
            e0.x |= pa; e0.y |= pa; e0.z |= pa;
            e1.x |= pa; e1.y |= pa; e1.z |= pa;
            e2.x |= pb; e2.y |= pb; e2.z |= pb;
            e3.x |= pb; e3.y |= pb; e3.z |= pb;
        } else {
            // Unique P-bit per endpoint, all four channels.
            uint p0 = bc_read_bit(bstream);
            e0.x |= p0; e0.y |= p0; e0.z |= p0; e0.w |= p0;
            uint p1 = bc_read_bit(bstream);
            e1.x |= p1; e1.y |= p1; e1.z |= p1; e1.w |= p1;
            if (numEndpoints > 2) {
                uint p2 = bc_read_bit(bstream);
                e2.x |= p2; e2.y |= p2; e2.z |= p2; e2.w |= p2;
                uint p3 = bc_read_bit(bstream);
                e3.x |= p3; e3.y |= p3; e3.z |= p3; e3.w |= p3;
            }
            if (numEndpoints > 4) {
                uint p4 = bc_read_bit(bstream);
                e4.x |= p4; e4.y |= p4; e4.z |= p4; e4.w |= p4;
                uint p5 = bc_read_bit(bstream);
                e5.x |= p5; e5.y |= p5; e5.z |= p5; e5.w |= p5;
            }
        }
    }
    uint precRGB = bitsRGB + pbitFlag;
    uint precA = bitsAlpha + pbitFlag;
    e0 = bc_bc7_expand(e0, precRGB, precA);
    e1 = bc_bc7_expand(e1, precRGB, precA);
    e2 = bc_bc7_expand(e2, precRGB, precA);
    e3 = bc_bc7_expand(e3, precRGB, precA);
    e4 = bc_bc7_expand(e4, precRGB, precA);
    e5 = bc_bc7_expand(e5, precRGB, precA);
    if (bitsAlpha == 0u) {
        // Modes without an explicit alpha channel sample alpha 1.0.
        e0.w = 0xFFu;
        e1.w = 0xFFu;
        e2.w = 0xFFu;
        e3.w = 0xFFu;
        e4.w = 0xFFu;
        e5.w = 0xFFu;
    }

    int indexBits = (mode == 0 || mode == 1) ? 3 : ((mode == 6) ? 4 : 2);
    int indexBits2 = (mode == 4) ? 3 : ((mode == 5) ? 2 : 0);

    // The colour indices for all sixteen texels form one contiguous section with
    // per-texel widths (fix-up texels carry one fewer bit), followed by the alpha
    // index section in modes 4/5. Both are read with absolute bit positions so no
    // per-texel storage array is needed.
    uint basePos = bstream.pos;
    uint totalColorBits = 0u;
    for (uint texel = 0u; texel < 16u; ++texel) {
        uint pv = bc_bc7_partition_value(numPartitions, partition, (int)(texel / 4u), (int)(texel % 4u), texel);
        totalColorBits += indexBits - (((pv & 0x80u) != 0u) ? 1u : 0u);
    }
    uint alphaBasePos = basePos + totalColorBits;

    uint baseX = blockCoord.x * 4u;
    uint baseY = blockCoord.y * 4u;
    for (uint row = 0; row < 4u; ++row) {
        for (uint col = 0; col < 4u; ++col) {
            uint texel = row * 4u + col;
            uint pv = bc_bc7_partition_value(numPartitions, partition, (int)row, (int)col, texel);
            bool isFixup = (pv & 0x80u) != 0u;
            uint subset = pv & 0x7Fu;
            uint bits = (uint)indexBits - (isFixup ? 1u : 0u);

            // Offset of this texel's colour index within the colour-index section.
            uint offset = 0u;
            for (uint u = 0u; u < texel; ++u) {
                uint pvU = bc_bc7_partition_value(numPartitions, partition, (int)(u / 4u), (int)(u % 4u), u);
                offset += (uint)indexBits - (((pvU & 0x80u) != 0u) ? 1u : 0u);
            }
            int index = (int)bc_read_bits_at(bstream, basePos + offset, bits);

            int r;
            int g;
            int b;
            int a;
            int weightColor = bc_bc7_weight(indexBits, index);
            uint4 epA = bc_bc7_ep(e0, e1, e2, e3, e4, e5, subset * 2u);
            uint4 epB = bc_bc7_ep(e0, e1, e2, e3, e4, e5, subset * 2u + 1u);
            if (indexBits2 == 0) {
                r = bc_bc7_interpolate((int)epA.x, (int)epB.x, weightColor);
                g = bc_bc7_interpolate((int)epA.y, (int)epB.y, weightColor);
                b = bc_bc7_interpolate((int)epA.z, (int)epB.z, weightColor);
                a = bc_bc7_interpolate((int)epA.w, (int)epB.w, weightColor);
            } else {
                // Alpha indices: texel 0 carries one fewer bit.
                uint alphaOffset = (texel == 0u) ? 0u : (indexBits2 - 1u) + (texel - 1u) * (uint)indexBits2;
                uint alphaBits = (texel == 0u) ? (uint)indexBits2 - 1u : (uint)indexBits2;
                int index2 = (int)bc_read_bits_at(bstream, alphaBasePos + alphaOffset, alphaBits);
                int weightAlpha = (indexBits2 == 2) ? mb_aWeight2[index2] : mb_aWeight3[index2];
                if (indexSelectionBit == 0) {
                    r = bc_bc7_interpolate((int)epA.x, (int)epB.x, weightColor);
                    g = bc_bc7_interpolate((int)epA.y, (int)epB.y, weightColor);
                    b = bc_bc7_interpolate((int)epA.z, (int)epB.z, weightColor);
                    a = bc_bc7_interpolate((int)epA.w, (int)epB.w, weightAlpha);
                } else {
                    r = bc_bc7_interpolate((int)epA.x, (int)epB.x, weightAlpha);
                    g = bc_bc7_interpolate((int)epA.y, (int)epB.y, weightAlpha);
                    b = bc_bc7_interpolate((int)epA.z, (int)epB.z, weightAlpha);
                    a = bc_bc7_interpolate((int)epA.w, (int)epB.w, weightColor);
                }
            }

            if (rotation == 1) { int t = a; a = r; r = t; }        /* Scalar(R) Vector(AGB) */
            else if (rotation == 2) { int t = a; a = g; g = t; }   /* Scalar(G) Vector(RAB) */
            else if (rotation == 3) { int t = a; a = b; b = t; }   /* Scalar(B) Vector(RGA) */

            output[(baseY + row) * params.widthPixels + baseX + col] =
                uchar4((uchar)r, (uchar)g, (uchar)b, (uchar)a);
        }
    }
}
constant uchar mb_bc6h_partition_sets[32][4][4] = {
    { {128, 0,   1, 1}, {0, 0, 1, 1}, {  0, 0, 1, 1}, {0, 0, 1, 129} }, /*  0 */
    { {128, 0,   0, 1}, {0, 0, 0, 1}, {  0, 0, 0, 1}, {0, 0, 0, 129} }, /*  1 */
    { {128, 1,   1, 1}, {0, 1, 1, 1}, {  0, 1, 1, 1}, {0, 1, 1, 129} }, /*  2 */
    { {128, 0,   0, 1}, {0, 0, 1, 1}, {  0, 0, 1, 1}, {0, 1, 1, 129} }, /*  3 */
    { {128, 0,   0, 0}, {0, 0, 0, 1}, {  0, 0, 0, 1}, {0, 0, 1, 129} }, /*  4 */
    { {128, 0,   1, 1}, {0, 1, 1, 1}, {  0, 1, 1, 1}, {1, 1, 1, 129} }, /*  5 */
    { {128, 0,   0, 1}, {0, 0, 1, 1}, {  0, 1, 1, 1}, {1, 1, 1, 129} }, /*  6 */
    { {128, 0,   0, 0}, {0, 0, 0, 1}, {  0, 0, 1, 1}, {0, 1, 1, 129} }, /*  7 */
    { {128, 0,   0, 0}, {0, 0, 0, 0}, {  0, 0, 0, 1}, {0, 0, 1, 129} }, /*  8 */
    { {128, 0,   1, 1}, {0, 1, 1, 1}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /*  9 */
    { {128, 0,   0, 0}, {0, 0, 0, 1}, {  0, 1, 1, 1}, {1, 1, 1, 129} }, /* 10 */
    { {128, 0,   0, 0}, {0, 0, 0, 0}, {  0, 0, 0, 1}, {0, 1, 1, 129} }, /* 11 */
    { {128, 0,   0, 1}, {0, 1, 1, 1}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /* 12 */
    { {128, 0,   0, 0}, {0, 0, 0, 0}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /* 13 */
    { {128, 0,   0, 0}, {1, 1, 1, 1}, {  1, 1, 1, 1}, {1, 1, 1, 129} }, /* 14 */
    { {128, 0,   0, 0}, {0, 0, 0, 0}, {  0, 0, 0, 0}, {1, 1, 1, 129} }, /* 15 */
    { {128, 0,   0, 0}, {1, 0, 0, 0}, {  1, 1, 1, 0}, {1, 1, 1, 129} }, /* 16 */
    { {128, 1, 129, 1}, {0, 0, 0, 1}, {  0, 0, 0, 0}, {0, 0, 0,   0} }, /* 17 */
    { {128, 0,   0, 0}, {0, 0, 0, 0}, {129, 0, 0, 0}, {1, 1, 1,   0} }, /* 18 */
    { {128, 1, 129, 1}, {0, 0, 1, 1}, {  0, 0, 0, 1}, {0, 0, 0,   0} }, /* 19 */
    { {128, 0, 129, 1}, {0, 0, 0, 1}, {  0, 0, 0, 0}, {0, 0, 0,   0} }, /* 20 */
    { {128, 0,   0, 0}, {1, 0, 0, 0}, {129, 1, 0, 0}, {1, 1, 1,   0} }, /* 21 */
    { {128, 0,   0, 0}, {0, 0, 0, 0}, {129, 0, 0, 0}, {1, 1, 0,   0} }, /* 22 */
    { {128, 1,   1, 1}, {0, 0, 1, 1}, {  0, 0, 1, 1}, {0, 0, 0, 129} }, /* 23 */
    { {128, 0, 129, 1}, {0, 0, 0, 1}, {  0, 0, 0, 1}, {0, 0, 0,   0} }, /* 24 */
    { {128, 0,   0, 0}, {1, 0, 0, 0}, {129, 0, 0, 0}, {1, 1, 0,   0} }, /* 25 */
    { {128, 1, 129, 0}, {0, 1, 1, 0}, {  0, 1, 1, 0}, {0, 1, 1,   0} }, /* 26 */
    { {128, 0, 129, 1}, {0, 1, 1, 0}, {  0, 1, 1, 0}, {1, 1, 0,   0} }, /* 27 */
    { {128, 0,   0, 1}, {0, 1, 1, 1}, {129, 1, 1, 0}, {1, 0, 0,   0} }, /* 28 */
    { {128, 0,   0, 0}, {1, 1, 1, 1}, {129, 1, 1, 1}, {0, 0, 0,   0} }, /* 29 */
    { {128, 1, 129, 1}, {0, 0, 0, 1}, {  1, 0, 0, 0}, {1, 1, 1,   0} }, /* 30 */
    { {128, 0, 129, 1}, {1, 0, 0, 1}, {  1, 0, 0, 1}, {1, 1, 0,   0} }  /* 31 */
};

constant char mb_bc6h_actual_bits[4][14] = {
    { 10, 7, 11, 11, 11, 9, 8, 8, 8, 6, 10, 11, 12, 16 },   //  W
    {  5, 6,  5,  4,  4, 5, 6, 5, 5, 6, 10,  9,  8,  4 },   // dR
    {  5, 6,  4,  5,  4, 5, 5, 6, 5, 6, 10,  9,  8,  4 },   // dG
    {  5, 6,  4,  4,  5, 5, 5, 5, 6, 6, 10,  9,  8,  4 }    // dB
};

// ---------------------------------------------------------------- BC6H helpers

static inline int bc_bc6h_extend_sign(int val, int bits) {
    return (val << (32 - bits)) >> (32 - bits);
}

static inline int bc_bc6h_transform_inverse(int val, int a0, int bits, bool isSigned) {
    val = (val + a0) & ((1 << bits) - 1);
    if (isSigned) {
        val = bc_bc6h_extend_sign(val, bits);
    }
    return val;
}

static inline int bc_bc6h_unquantize(int val, int bits, bool isSigned) {
    int unq;
    if (!isSigned) {
        if (bits >= 15) {
            unq = val;
        } else if (val == 0) {
            unq = 0;
        } else if (val == ((1 << bits) - 1)) {
            unq = 0xFFFF;
        } else {
            unq = ((val << 16) + 0x8000) >> bits;
        }
    } else {
        int s = 0;
        if (val < 0) {
            s = 1;
            val = -val;
        }
        if (val == 0) {
            unq = 0;
        } else if (val >= ((1 << (bits - 1)) - 1)) {
            unq = 0x7FFF;
        } else {
            unq = ((val << 15) + 0x4000) >> (bits - 1);
        }
        if (s != 0) {
            unq = -unq;
        }
    }
    return unq;
}

static inline int bc_bc6h_interpolate(int a, int b, int weight) {
    if (weight == 0) { return a; }
    if (weight == 64) { return b; }
    return (a * (64 - weight) + b * weight + 32) >> 6;
}

static inline int bc_bc6h_weight(int mode, int index) {
    if (mode >= 10) { return mb_aWeight4[index]; }
    return mb_aWeight3[index];
}

static inline ushort bc_bc6h_finish_unquantize(int val, bool isSigned) {
    if (!isSigned) {
        return (ushort)((val * 31) >> 6);
    }
    val = (val < 0) ? -(((-val) * 31) >> 5) : (val * 31) >> 5;
    int s = 0;
    if (val < 0) {
        s = 0x8000;
        val = -val;
    }
    return (ushort)(s | val);
}

// ---------------------------------------------------------------- BC6H

kernel void mb_bc6h_decode(const device uchar* blocks [[buffer(0)]],
                           device half4* output [[buffer(1)]],
                           constant BCParams& params [[buffer(2)]],
                           uint2 blockCoord [[thread_position_in_grid]]) {
    // The dispatch grid can be padded (dispatchThreads rounds the grid up to whole
    // threadgroups and [[threads_per_grid]] reports the padded size), so the logical
    // block dimensions come from params, never from the dispatch.
    uint2 gridSize = uint2((params.widthPixels + 3u) >> 2, (params.heightPixels + 3u) >> 2);
    if (blockCoord.x >= gridSize.x || blockCoord.y >= gridSize.y) { return; }
    const device uchar* block = blocks + (blockCoord.y * gridSize.x + blockCoord.x) * 16;
    bool isSigned = (params.flags & 1u) != 0u;

    BCBitStream bstream;
    bstream.low = bc_get_u64(block);
    bstream.high = bc_get_u64(block + 8);
    bstream.pos = 0u;
    bstream.origLow = bstream.low;
    bstream.origHigh = bstream.high;

    // Endpoints as scalars: r/g/b, four endpoint slots each (the giant mode
    // switch below writes only constant indices, which MSL 1.x handles fine).
    int r0 = 0;
    int r1 = 0;
    int r2 = 0;
    int r3 = 0;
    int g0 = 0;
    int g1 = 0;
    int g2 = 0;
    int g3 = 0;
    int b0 = 0;
    int b1 = 0;
    int b2 = 0;
    int b3 = 0;

    int mode = (int)bc_read_bits(bstream, 2);
    if (mode > 1) {
        mode |= (int)bc_read_bits(bstream, 3) << 2;
    }

    int partition = 0;
    switch (mode) {
        case 0: { // spec mode 1: (10.555, 10.555, 10.555)
            g2 |= (int)bc_read_bit(bstream) << 4;
            b2 |= (int)bc_read_bit(bstream) << 4;
            b3 |= (int)bc_read_bit(bstream) << 4;
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 5);
            g3 |= (int)bc_read_bit(bstream) << 4;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 0;
        } break;
        case 1: { // spec mode 2: (7666, 7666, 7666)
            g2 |= (int)bc_read_bit(bstream) << 5;
            g3 |= (int)bc_read_bit(bstream) << 4;
            g3 |= (int)bc_read_bit(bstream) << 5;
            r0 |= (int)bc_read_bits(bstream, 7);
            b3 |= (int)bc_read_bit(bstream);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bit(bstream) << 4;
            g0 |= (int)bc_read_bits(bstream, 7);
            b2 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 2;
            g2 |= (int)bc_read_bit(bstream) << 4;
            b0 |= (int)bc_read_bits(bstream, 7);
            b3 |= (int)bc_read_bit(bstream) << 3;
            b3 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 4;
            r1 |= (int)bc_read_bits(bstream, 6);
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 6);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 6);
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 6);
            r3 |= (int)bc_read_bits(bstream, 6);
            partition = (int)bc_read_bits(bstream, 5);
            mode = 1;
        } break;
        case 2: { // spec mode 3: (11.555, 11.444, 11.444)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 5);
            r0 |= (int)bc_read_bit(bstream) << 10;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 4);
            g0 |= (int)bc_read_bit(bstream) << 10;
            b3 |= (int)bc_read_bit(bstream);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 4);
            b0 |= (int)bc_read_bit(bstream) << 10;
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 2;
        } break;
        case 6: { // spec mode 4: (11.444, 11.555, 11.444)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 4);
            r0 |= (int)bc_read_bit(bstream) << 10;
            g3 |= (int)bc_read_bit(bstream) << 4;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 5);
            g0 |= (int)bc_read_bit(bstream) << 10;
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 4);
            b0 |= (int)bc_read_bit(bstream) << 10;
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 4);
            b3 |= (int)bc_read_bit(bstream);
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 4);
            g2 |= (int)bc_read_bit(bstream) << 4;
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 3;
        } break;
        case 10: { // spec mode 5: (11.444, 11.444, 11.555)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 4);
            r0 |= (int)bc_read_bit(bstream) << 10;
            b2 |= (int)bc_read_bit(bstream) << 4;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 4);
            g0 |= (int)bc_read_bit(bstream) << 10;
            b3 |= (int)bc_read_bit(bstream);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 5);
            b0 |= (int)bc_read_bit(bstream) << 10;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 4);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 4);
            b3 |= (int)bc_read_bit(bstream) << 4;
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 4;
        } break;
        case 14: { // spec mode 6: (9555, 9555, 9555)
            r0 |= (int)bc_read_bits(bstream, 9);
            b2 |= (int)bc_read_bit(bstream) << 4;
            g0 |= (int)bc_read_bits(bstream, 9);
            g2 |= (int)bc_read_bit(bstream) << 4;
            b0 |= (int)bc_read_bits(bstream, 9);
            b3 |= (int)bc_read_bit(bstream) << 4;
            r1 |= (int)bc_read_bits(bstream, 5);
            g3 |= (int)bc_read_bit(bstream) << 4;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 5;
        } break;
        case 18: { // spec mode 7: (8666, 8555, 8555)
            r0 |= (int)bc_read_bits(bstream, 8);
            g3 |= (int)bc_read_bit(bstream) << 4;
            b2 |= (int)bc_read_bit(bstream) << 4;
            g0 |= (int)bc_read_bits(bstream, 8);
            b3 |= (int)bc_read_bit(bstream) << 2;
            g2 |= (int)bc_read_bit(bstream) << 4;
            b0 |= (int)bc_read_bits(bstream, 8);
            b3 |= (int)bc_read_bit(bstream) << 3;
            b3 |= (int)bc_read_bit(bstream) << 4;
            r1 |= (int)bc_read_bits(bstream, 6);
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 6);
            r3 |= (int)bc_read_bits(bstream, 6);
            partition = (int)bc_read_bits(bstream, 5);
            mode = 6;
        } break;
        case 22: { // spec mode 8: (8555, 8666, 8555)
            r0 |= (int)bc_read_bits(bstream, 8);
            b3 |= (int)bc_read_bit(bstream);
            b2 |= (int)bc_read_bit(bstream) << 4;
            g0 |= (int)bc_read_bits(bstream, 8);
            g2 |= (int)bc_read_bit(bstream) << 5;
            g2 |= (int)bc_read_bit(bstream) << 4;
            b0 |= (int)bc_read_bits(bstream, 8);
            g3 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 4;
            r1 |= (int)bc_read_bits(bstream, 5);
            g3 |= (int)bc_read_bit(bstream) << 4;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 6);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 7;
        } break;
        case 26: { // spec mode 9: (8555, 8555, 8666)
            r0 |= (int)bc_read_bits(bstream, 8);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bit(bstream) << 4;
            g0 |= (int)bc_read_bits(bstream, 8);
            b2 |= (int)bc_read_bit(bstream) << 5;
            g2 |= (int)bc_read_bit(bstream) << 4;
            b0 |= (int)bc_read_bits(bstream, 8);
            b3 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 4;
            r1 |= (int)bc_read_bits(bstream, 5);
            g3 |= (int)bc_read_bit(bstream) << 4;
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 6);
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 2;
            r3 |= (int)bc_read_bits(bstream, 5);
            b3 |= (int)bc_read_bit(bstream) << 3;
            partition = (int)bc_read_bits(bstream, 5);
            mode = 8;
        } break;
        case 30: { // spec mode 10: (6666, 6666, 6666)
            r0 |= (int)bc_read_bits(bstream, 6);
            g3 |= (int)bc_read_bit(bstream) << 4;
            b3 |= (int)bc_read_bit(bstream);
            b3 |= (int)bc_read_bit(bstream) << 1;
            b2 |= (int)bc_read_bit(bstream) << 4;
            g0 |= (int)bc_read_bits(bstream, 6);
            g2 |= (int)bc_read_bit(bstream) << 5;
            b2 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 2;
            g2 |= (int)bc_read_bit(bstream) << 4;
            b0 |= (int)bc_read_bits(bstream, 6);
            g3 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 3;
            b3 |= (int)bc_read_bit(bstream) << 5;
            b3 |= (int)bc_read_bit(bstream) << 4;
            r1 |= (int)bc_read_bits(bstream, 6);
            g2 |= (int)bc_read_bits(bstream, 4);
            g1 |= (int)bc_read_bits(bstream, 6);
            g3 |= (int)bc_read_bits(bstream, 4);
            b1 |= (int)bc_read_bits(bstream, 6);
            b2 |= (int)bc_read_bits(bstream, 4);
            r2 |= (int)bc_read_bits(bstream, 6);
            r3 |= (int)bc_read_bits(bstream, 6);
            partition = (int)bc_read_bits(bstream, 5);
            mode = 9;
        } break;
        case 3: { // spec mode 11: (10.10, 10.10, 10.10)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 10);
            g1 |= (int)bc_read_bits(bstream, 10);
            b1 |= (int)bc_read_bits(bstream, 10);
            mode = 10;
        } break;
        case 7: { // spec mode 12: (11.9, 11.9, 11.9)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 9);
            r0 |= (int)bc_read_bit(bstream) << 10;
            g1 |= (int)bc_read_bits(bstream, 9);
            g0 |= (int)bc_read_bit(bstream) << 10;
            b1 |= (int)bc_read_bits(bstream, 9);
            b0 |= (int)bc_read_bit(bstream) << 10;
            mode = 11;
        } break;
        case 11: { // spec mode 13: (12.8, 12.8, 12.8)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 8);
            r0 |= (int)bc_read_bits_reversed(bstream, 2) << 10;
            g1 |= (int)bc_read_bits(bstream, 8);
            g0 |= (int)bc_read_bits_reversed(bstream, 2) << 10;
            b1 |= (int)bc_read_bits(bstream, 8);
            b0 |= (int)bc_read_bits_reversed(bstream, 2) << 10;
            mode = 12;
        } break;
        case 15: { // spec mode 14: (16.4, 16.4, 16.4)
            r0 |= (int)bc_read_bits(bstream, 10);
            g0 |= (int)bc_read_bits(bstream, 10);
            b0 |= (int)bc_read_bits(bstream, 10);
            r1 |= (int)bc_read_bits(bstream, 4);
            r0 |= (int)bc_read_bits_reversed(bstream, 6) << 10;
            g1 |= (int)bc_read_bits(bstream, 4);
            g0 |= (int)bc_read_bits_reversed(bstream, 6) << 10;
            b1 |= (int)bc_read_bits(bstream, 4);
            b0 |= (int)bc_read_bits_reversed(bstream, 6) << 10;
            mode = 13;
        } break;
        default: {
            // Reserved modes: output transparent black (alpha is defined as 1.0 for BC6H).
            uint base = blockCoord.y * 4u * params.widthPixels + blockCoord.x * 4u;
            for (uint row = 0; row < 4u; ++row) {
                for (uint col = 0; col < 4u; ++col) {
                    output[base + row * params.widthPixels + col] = half4(0.0h, 0.0h, 0.0h, 1.0h);
                }
            }
            return;
        }
    }
    int numPartitions = (mode >= 10) ? 0 : 1;
    int actualBits0Mode = mb_bc6h_actual_bits[0][mode];

    if (isSigned) {
        r0 = bc_bc6h_extend_sign(r0, actualBits0Mode);
        g0 = bc_bc6h_extend_sign(g0, actualBits0Mode);
        b0 = bc_bc6h_extend_sign(b0, actualBits0Mode);
    }

    // Endpoints 1..count-1 (count = (numPartitions + 1) * 2), unrolled so no
    // thread-space array is ever indexed dynamically.
    if ((mode != 9 && mode != 10) || isSigned) {
        r1 = bc_bc6h_extend_sign(r1, mb_bc6h_actual_bits[1][mode]);
        g1 = bc_bc6h_extend_sign(g1, mb_bc6h_actual_bits[2][mode]);
        b1 = bc_bc6h_extend_sign(b1, mb_bc6h_actual_bits[3][mode]);
        if (numPartitions == 1) {
            r2 = bc_bc6h_extend_sign(r2, mb_bc6h_actual_bits[1][mode]);
            g2 = bc_bc6h_extend_sign(g2, mb_bc6h_actual_bits[2][mode]);
            b2 = bc_bc6h_extend_sign(b2, mb_bc6h_actual_bits[3][mode]);
            r3 = bc_bc6h_extend_sign(r3, mb_bc6h_actual_bits[1][mode]);
            g3 = bc_bc6h_extend_sign(g3, mb_bc6h_actual_bits[2][mode]);
            b3 = bc_bc6h_extend_sign(b3, mb_bc6h_actual_bits[3][mode]);
        }
    }

    if (mode != 9 && mode != 10) {
        // bcdec passes the A0 endpoint's bit count for every channel here.
        r1 = bc_bc6h_transform_inverse(r1, r0, actualBits0Mode, isSigned);
        g1 = bc_bc6h_transform_inverse(g1, g0, actualBits0Mode, isSigned);
        b1 = bc_bc6h_transform_inverse(b1, b0, actualBits0Mode, isSigned);
        if (numPartitions == 1) {
            r2 = bc_bc6h_transform_inverse(r2, r0, actualBits0Mode, isSigned);
            g2 = bc_bc6h_transform_inverse(g2, g0, actualBits0Mode, isSigned);
            b2 = bc_bc6h_transform_inverse(b2, b0, actualBits0Mode, isSigned);
            r3 = bc_bc6h_transform_inverse(r3, r0, actualBits0Mode, isSigned);
            g3 = bc_bc6h_transform_inverse(g3, g0, actualBits0Mode, isSigned);
            b3 = bc_bc6h_transform_inverse(b3, b0, actualBits0Mode, isSigned);
        }
    }

    r0 = bc_bc6h_unquantize(r0, actualBits0Mode, isSigned);
    g0 = bc_bc6h_unquantize(g0, actualBits0Mode, isSigned);
    b0 = bc_bc6h_unquantize(b0, actualBits0Mode, isSigned);
    r1 = bc_bc6h_unquantize(r1, actualBits0Mode, isSigned);
    g1 = bc_bc6h_unquantize(g1, actualBits0Mode, isSigned);
    b1 = bc_bc6h_unquantize(b1, actualBits0Mode, isSigned);
    if (numPartitions == 1) {
        r2 = bc_bc6h_unquantize(r2, actualBits0Mode, isSigned);
        g2 = bc_bc6h_unquantize(g2, actualBits0Mode, isSigned);
        b2 = bc_bc6h_unquantize(b2, actualBits0Mode, isSigned);
        r3 = bc_bc6h_unquantize(r3, actualBits0Mode, isSigned);
        g3 = bc_bc6h_unquantize(g3, actualBits0Mode, isSigned);
        b3 = bc_bc6h_unquantize(b3, actualBits0Mode, isSigned);
    }

    uint baseX = blockCoord.x * 4u;
    uint baseY = blockCoord.y * 4u;
    for (uint row = 0; row < 4u; ++row) {
        for (uint col = 0; col < 4u; ++col) {
            uint subsetFlag = (mode >= 10) ? ((row == 0u && col == 0u) ? 0x80u : 0u)
                                           : (uint)mb_bc6h_partition_sets[partition][row][col];
            uint indexBits = (mode >= 10) ? 4u : 3u;
            if (subsetFlag & 0x80u) {
                indexBits -= 1u; // fix-up index carries one fewer bit
            }
            uint subset = subsetFlag & 0x1u;
            int index = (int)bc_read_bits(bstream, indexBits);
            int weight = bc_bc6h_weight(mode, index);
            int rA = (subset == 0u) ? r0 : r2;
            int rB = (subset == 0u) ? r1 : r3;
            int gA = (subset == 0u) ? g0 : g2;
            int gB = (subset == 0u) ? g1 : g3;
            int bA = (subset == 0u) ? b0 : b2;
            int bB = (subset == 0u) ? b1 : b3;
            half3 color = half3(
                as_type<half>(bc_bc6h_finish_unquantize(bc_bc6h_interpolate(rA, rB, weight), isSigned)),
                as_type<half>(bc_bc6h_finish_unquantize(bc_bc6h_interpolate(gA, gB, weight), isSigned)),
                as_type<half>(bc_bc6h_finish_unquantize(bc_bc6h_interpolate(bA, bB, weight), isSigned)));
            output[(baseY + row) * params.widthPixels + baseX + col] = half4(color, 1.0h);
        }
    }
}
