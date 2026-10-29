#include <metal_stdlib>
using namespace metal;

// Debug harness kernel: reports what BC1 index parsing produces for one block.
struct DbgParams {
    uint widthPixels;
    uint heightPixels;
    uint flags;
};

static inline uint dbg_get_u32(const device uchar* p) {
    return (uint)p[0] | ((uint)p[1] << 8) | ((uint)p[2] << 16) | ((uint)p[3] << 24);
}

kernel void dbg_bc1(device const uchar* blocks [[buffer(0)]],
                    device uint* report [[buffer(1)]],
                    uint tid [[thread_position_in_grid]]) {
    if (tid > 0) return;
    const device uchar* block = blocks;
    uint c0 = (uint)block[0] | ((uint)block[1] << 8);
    uint c1 = (uint)block[2] | ((uint)block[3] << 8);
    uint indices = dbg_get_u32(block + 4);
    report[0] = c0;
    report[1] = c1;
    report[2] = indices;
    uint out[16];
    uint ci = indices;
    for (uint t = 0; t < 16; ++t) {
        out[t] = ci & 3u;
        ci >>= 2;
    }
    for (uint t = 0; t < 16; ++t) {
        report[3 + t] = out[t];
    }
}
