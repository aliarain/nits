#import "NitsPrivate.h"
#import <Foundation/Foundation.h>
#import <objc/message.h>

// CGVirtualDisplay and friends are private CoreGraphics classes absent from the SDK
// headers. They are reached with NSClassFromString + objc_msgSend, so nothing private is
// linked. Verified on macOS 27.2 (create, apply, displayID, teardown).

static id NitsMsgSendInitWithDescriptor(id object, SEL selector, id descriptor) {
    return ((id (*)(id, SEL, id))objc_msgSend)(object, selector, descriptor);
}

static id NitsMsgSendInitMode(id object, SEL selector, NSUInteger width, NSUInteger height, double refresh) {
    return ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
        object, selector, width, height, refresh
    );
}

NitsVirtualDisplayRef NitsVirtualDisplayCreate(
    const char *name,
    uint32_t width,
    uint32_t height,
    uint32_t vendorID,
    uint32_t productID,
    uint32_t serialNumber
) {
    @autoreleasepool {
        Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
        Class displayClass = NSClassFromString(@"CGVirtualDisplay");
        if (descriptorClass == Nil || displayClass == Nil) {
            return NULL;
        }

        id descriptor = [[descriptorClass alloc] init];
        [descriptor setValue:@(width) forKey:@"maxPixelsWide"];
        [descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
        // Fixed 110 PPI makes macOS default to the native resolution instead of a
        // scaled Retina mode, the same trick BetterDisplay/Crisp use.
        const double ppi = 110.0;
        NSSize size = NSMakeSize(width / ppi * 25.4, height / ppi * 25.4);
        [descriptor setValue:[NSValue valueWithSize:size] forKey:@"sizeInMillimeters"];
        NSString *displayName = name ? [NSString stringWithUTF8String:name] : @"Nits Virtual";
        [descriptor setValue:displayName forKey:@"name"];
        [descriptor setValue:@(vendorID) forKey:@"vendorID"];
        [descriptor setValue:@(productID) forKey:@"productID"];
        [descriptor setValue:@(serialNumber) forKey:@"serialNum"];

        id display = NitsMsgSendInitWithDescriptor(
            [displayClass alloc],
            sel_registerName("initWithDescriptor:"),
            descriptor
        );
        if (display == nil) {
            return NULL;
        }
        return (__bridge_retained void *)display;
    }
}

bool NitsVirtualDisplayApply(
    NitsVirtualDisplayRef ref,
    uint32_t width,
    uint32_t height,
    double refreshRate,
    bool hiDPI
) {
    if (ref == NULL) {
        return false;
    }
    @autoreleasepool {
        id display = (__bridge id)ref;
        Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
        Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
        if (settingsClass == Nil || modeClass == Nil) {
            return false;
        }

        id settings = [[settingsClass alloc] init];
        [settings setValue:@(hiDPI) forKey:@"hiDPI"];

        NSMutableArray *modes = [NSMutableArray array];
        double rates[] = { refreshRate, 60.0, 50.0 };
        int rateCount = sizeof(rates) / sizeof(rates[0]);
        for (int i = 0; i < rateCount; i++) {
            if (i > 0 && rates[i] >= rates[0]) {
                continue;
            }
            id mode = NitsMsgSendInitMode(
                [modeClass alloc],
                sel_registerName("initWithWidth:height:refreshRate:"),
                width, height, rates[i]
            );
            if (mode) { [modes addObject:mode]; }
        }
        if (hiDPI) {
            uint32_t halfWidth = width / 2;
            uint32_t halfHeight = height / 2;
            if (halfWidth > 0 && halfHeight > 0) {
                for (int i = 0; i < rateCount; i++) {
                    if (i > 0 && rates[i] >= rates[0]) { continue; }
                    id mode = NitsMsgSendInitMode(
                        [modeClass alloc],
                        sel_registerName("initWithWidth:height:refreshRate:"),
                        halfWidth, halfHeight, rates[i]
                    );
                    if (mode) { [modes addObject:mode]; }
                }
            }
            uint32_t quarterWidth = width / 4;
            uint32_t quarterHeight = height / 4;
            if (quarterWidth > 0 && quarterHeight > 0) {
                for (int i = 0; i < rateCount; i++) {
                    if (i > 0 && rates[i] >= rates[0]) { continue; }
                    id mode = NitsMsgSendInitMode(
                        [modeClass alloc],
                        sel_registerName("initWithWidth:height:refreshRate:"),
                        quarterWidth, quarterHeight, rates[i]
                    );
                    if (mode) { [modes addObject:mode]; }
                }
            }
        }
        [settings setValue:modes forKey:@"modes"];

        BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(
            display,
            sel_registerName("applySettings:"),
            settings
        );
        return ok == YES;
    }
}

CGDirectDisplayID NitsVirtualDisplayID(NitsVirtualDisplayRef ref) {
    if (ref == NULL) {
        return kCGNullDirectDisplay;
    }
    id display = (__bridge id)ref;
    return ((CGDirectDisplayID (*)(id, SEL))objc_msgSend)(
        display,
        sel_registerName("displayID")
    );
}

void NitsVirtualDisplayDestroy(NitsVirtualDisplayRef ref) {
    if (ref == NULL) {
        return;
    }
    // Transfer the +1 reference back to ARC and let it release the object.
    id display = (__bridge_transfer id)ref;
    (void)display;
}
