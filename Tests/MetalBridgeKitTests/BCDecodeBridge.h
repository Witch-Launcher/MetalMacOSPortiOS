#ifndef BC_DECODE_BRIDGE_H
#define BC_DECODE_BRIDGE_H

// Exposes the vendored bcdec reference decoder (third_party/bcdec) to the Swift
// differential tests: the CPU results are ground truth, the GPU kernels must
// reproduce them texel for texel.

#include <stdint.h>

void bcdec_bc1(const void* compressedBlock, void* decompressedBlock, int destinationPitch);
void bcdec_bc2(const void* compressedBlock, void* decompressedBlock, int destinationPitch);
void bcdec_bc3(const void* compressedBlock, void* decompressedBlock, int destinationPitch);
void bcdec_bc4(const void* compressedBlock, void* decompressedBlock, int destinationPitch, int isSigned);
void bcdec_bc5(const void* compressedBlock, void* decompressedBlock, int destinationPitch, int isSigned);
void bcdec_bc6h_half(const void* compressedBlock, void* decompressedBlock, int destinationPitch, int isSigned);
void bcdec_bc7(const void* compressedBlock, void* decompressedBlock, int destinationPitch);

#endif
