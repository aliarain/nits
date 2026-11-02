#ifndef NITS_PRIVATE_H
#define NITS_PRIVATE_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>
#include <stdint.h>

/// Opaque strong reference to a CGVirtualDisplay object.
typedef void *NitsVirtualDisplayRef;

/// Creates the private descriptor and CGVirtualDisplay object. Must run on the main
/// thread (the initializer returns nil elsewhere). No modes are applied yet.
NitsVirtualDisplayRef NitsVirtualDisplayCreate(
    const char *name,
    uint32_t width,
    uint32_t height,
    uint32_t vendorID,
    uint32_t productID,
    uint32_t serialNumber
);

/// Declares and applies the mode set. Runs off the main thread; may block on WindowServer.
bool NitsVirtualDisplayApply(
    NitsVirtualDisplayRef ref,
    uint32_t width,
    uint32_t height,
    double refreshRate,
    bool hiDPI
);

CGDirectDisplayID NitsVirtualDisplayID(NitsVirtualDisplayRef ref);

/// Releasing the last reference destroys the virtual display.
void NitsVirtualDisplayDestroy(NitsVirtualDisplayRef ref);

#endif
