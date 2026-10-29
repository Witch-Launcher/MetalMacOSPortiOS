#ifndef BCDEC_SWIFT_BRIDGE_H
#define BCDEC_SWIFT_BRIDGE_H

#include <stdint.h>

void bcdec_bc1(const void* compressedBlock, void* decompressedBlock, int destinationPitch);
void bcdec_bc2(const void* compressedBlock, void* decompressedBlock, int destinationPitch);
void bcdec_bc3(const void* compressedBlock, void* decompressedBlock, int destinationPitch);
void bcdec_bc4(const void* compressedBlock, void* decompressedBlock, int destinationPitch, int isSigned);
void bcdec_bc5(const void* compressedBlock, void* decompressedBlock, int destinationPitch, int isSigned);
void bcdec_bc6h_half(const void* compressedBlock, void* decompressedBlock, int destinationPitch, int isSigned);
void bcdec_bc7(const void* compressedBlock, void* decompressedBlock, int destinationPitch);

#endif
