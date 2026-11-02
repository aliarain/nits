import Foundation

/// Pure pairing of DDC I2C channels to display IDs on Apple Silicon.
///
/// Both arrays are order-sensitive: channels are in IORegistry traversal order, displays
/// are in `CGGetOnlineDisplayList` order. Matching is location first, then full
/// vendor/product/serial, then vendor/product, then traversal order for the leftovers.
public enum DDCPairing {
    public struct Result: Equatable, Sendable {
        /// Channel index chosen for each display ID.
        public let byDisplayID: [UInt32: Int]
        /// True when the traversal fallback had to guess among more than one display.
        public let ambiguous: Bool
        /// Number of channels that matched by stable identity rather than traversal order.
        public let identityMatches: Int

        public init(byDisplayID: [UInt32: Int], ambiguous: Bool, identityMatches: Int) {
            self.byDisplayID = byDisplayID
            self.ambiguous = ambiguous
            self.identityMatches = identityMatches
        }
    }

    public static func match(
        channels: [DisplayIdentity?],
        displays: [(id: UInt32, identity: DisplayIdentity)]
    ) -> Result {
        var byDisplayID: [UInt32: Int] = [:]
        var usedDisplays = Set<UInt32>()
        var unmatched: [Int] = []
        var identityMatches = 0

        for index in channels.indices {
            guard let channel = channels[index] else {
                unmatched.append(index)
                continue
            }

            let byLocation = displays.first { display in
                guard let location = channel.location, !location.isEmpty else { return false }
                return !usedDisplays.contains(display.id) && display.identity.location == location
            }

            let exact = byLocation ?? displays.first { display in
                !usedDisplays.contains(display.id)
                    && channel.serial != 0
                    && display.identity.serial != 0
                    && display.identity.vendor == channel.vendor
                    && display.identity.product == channel.product
                    && display.identity.serial == channel.serial
            }

            let byModel = exact ?? displays.first { display in
                !usedDisplays.contains(display.id)
                    && display.identity.vendor == channel.vendor
                    && display.identity.product == channel.product
            }

            if let matched = byModel {
                byDisplayID[matched.id] = index
                usedDisplays.insert(matched.id)
                if exact != nil || byLocation != nil {
                    identityMatches += 1
                }
            } else {
                unmatched.append(index)
            }
        }

        let leftovers = displays.map(\.id).filter { !usedDisplays.contains($0) }.sorted()
        for (offset, channelIndex) in unmatched.enumerated() where offset < leftovers.count {
            byDisplayID[leftovers[offset]] = channelIndex
        }

        let ambiguous = !unmatched.isEmpty && leftovers.count > 1
        return Result(
            byDisplayID: byDisplayID,
            ambiguous: ambiguous,
            identityMatches: identityMatches
        )
    }
}
