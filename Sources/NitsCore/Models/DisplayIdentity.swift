import Foundation

/// The physical identity of a display, independent of the volatile CGDirectDisplayID.
/// Two identical monitors share vendor/product/serial; the IORegistry location is what
/// tells them apart when macOS reshuffles IDs.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var product: UInt32
    public var serial: UInt32
    public var location: String?

    public init(vendor: UInt32, product: UInt32, serial: UInt32, location: String? = nil) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.location = location
    }

    public var vendorProduct: String {
        String(format: "0x%04X:0x%04X", vendor, product)
    }
}

public struct DisplayBounds: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct DisplaySnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var name: String
    public var identity: DisplayIdentity
    public var isBuiltin: Bool
    public var isMain: Bool
    public var isActive: Bool
    public var isVirtual: Bool
    public var bounds: DisplayBounds
    public var rotation: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var nativeWidth: Int
    public var nativeHeight: Int
    public var panelWidth: Int
    public var panelHeight: Int
    public var hasNativeBrightness: Bool
    public var maximumEDR: Double
    public var nominalMaxNits: Double? = nil
    public var connection: String

    public init(
        id: UInt32,
        uuid: String,
        name: String,
        identity: DisplayIdentity,
        isBuiltin: Bool,
        isMain: Bool,
        isActive: Bool,
        isVirtual: Bool = false,
        bounds: DisplayBounds,
        rotation: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        nativeWidth: Int,
        nativeHeight: Int,
        panelWidth: Int,
        panelHeight: Int,
        hasNativeBrightness: Bool,
        maximumEDR: Double = 1.0,
        nominalMaxNits: Double? = nil,
        connection: String
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.identity = identity
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.isActive = isActive
        self.isVirtual = isVirtual
        self.bounds = bounds
        self.rotation = rotation
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.nativeWidth = nativeWidth
        self.nativeHeight = nativeHeight
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        self.hasNativeBrightness = hasNativeBrightness
        self.maximumEDR = maximumEDR
        self.nominalMaxNits = nominalMaxNits
        self.connection = connection
    }

    public var isRotated: Bool {
        Int(rotation.rounded()) % 180 != 0
    }

    public var resolutionLabel: String {
        "\(pixelWidth)×\(pixelHeight)"
    }

    /// A short label for pickers and CLI output.
    public var shortLabel: String {
        "\(name) [\(id)]"
    }
}

public enum DisplaySelector {
    /// Accepts "main", "builtin"/"internal", "external", a UUID prefix, a numeric
    /// CGDirectDisplayID, or a case-insensitive name substring. nil means "the main
    /// display" when no term is supplied.
    public static func match(_ term: String?, in displays: [DisplaySnapshot]) -> DisplaySnapshot? {
        guard let term, !term.isEmpty else {
            return displays.first(where: \.isMain) ?? displays.first
        }
        let lowered = term.lowercased()

        switch lowered {
        case "main", "primary":
            return displays.first(where: \.isMain) ?? displays.first
        case "builtin", "internal", "laptop":
            return displays.first(where: \.isBuiltin)
        case "external":
            return displays.first { !$0.isBuiltin }
        case "all":
            return nil
        default:
            break
        }

        if let id = UInt32(term), let exact = displays.first(where: { $0.id == id }) {
            return exact
        }
        if let uuid = displays.first(where: {
            $0.uuid.lowercased().hasPrefix(lowered) || $0.uuid.lowercased() == lowered
        }) {
            return uuid
        }
        return displays.first { $0.name.lowercased().contains(lowered) }
    }

    public static func matchAll(_ term: String?, in displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        guard let term, term.lowercased() == "all" else {
            return match(term, in: displays).map { [$0] } ?? []
        }
        return displays
    }
}
