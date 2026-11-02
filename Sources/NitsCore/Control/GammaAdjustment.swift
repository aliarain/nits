import Foundation

/// Per-display software image adjustment. Slider values are -100...+100 with 0 neutral,
/// except quantizationLevels (2...256, 256 = off). The same transfer table is used for
/// software dimming, so this is the one place that owns the display's ramp.
public struct GammaAdjustment: Codable, Hashable, Sendable {
    public var contrast: Double = 0
    public var gamma: Double = 0
    public var gain: Double = 0
    public var colorTemperature: Double = 0
    public var redGamma: Double = 0
    public var greenGamma: Double = 0
    public var blueGamma: Double = 0
    public var redGain: Double = 0
    public var greenGain: Double = 0
    public var blueGain: Double = 0
    public var quantizationLevels: Int = 256
    public var isInverted: Bool = false
    public var isPaused: Bool = false

    public init() {}

    public var isNeutral: Bool {
        contrast == 0 && gamma == 0 && gain == 0 && colorTemperature == 0 &&
        redGamma == 0 && greenGamma == 0 && blueGamma == 0 &&
        redGain == 0 && greenGain == 0 && blueGain == 0 &&
        quantizationLevels == 256 && !isInverted
    }

    public func interpolated(to target: GammaAdjustment, fraction: Double) -> GammaAdjustment {
        guard fraction < 1 else { return target }
        func mix(_ from: Double, _ to: Double) -> Double { from + (to - from) * fraction }
        var step = self
        step.contrast = mix(contrast, target.contrast)
        step.gamma = mix(gamma, target.gamma)
        step.gain = mix(gain, target.gain)
        step.colorTemperature = mix(colorTemperature, target.colorTemperature)
        step.redGamma = mix(redGamma, target.redGamma)
        step.greenGamma = mix(greenGamma, target.greenGamma)
        step.blueGamma = mix(blueGamma, target.blueGamma)
        step.redGain = mix(redGain, target.redGain)
        step.greenGain = mix(greenGain, target.greenGain)
        step.blueGain = mix(blueGain, target.blueGain)
        step.quantizationLevels = Int(
            mix(Double(quantizationLevels), Double(target.quantizationLevels)).rounded()
        )
        return step
    }
}

/// The transfer-table math, kept pure so the curves can be checked without a display.
public enum GammaMath {
    public static let tableSize = 256

    public static func tables(
        adjustment: GammaAdjustment,
        softwareFactor: Double
    ) -> (red: [Double], green: [Double], blue: [Double]) {
        var params = channelParams(adjustment)
        let factor = min(1.5, max(0.01, softwareFactor))
        params.rHi *= factor
        params.gHi *= factor
        params.bHi *= factor
        let cap = max(1.0, factor)

        var red = [Double](repeating: 0, count: tableSize)
        var green = [Double](repeating: 0, count: tableSize)
        var blue = [Double](repeating: 0, count: tableSize)
        let levels = max(2, min(255, adjustment.quantizationLevels))

        for index in 0..<tableSize {
            let input = Double(index) / Double(tableSize - 1)
            func value(lo: Double, hi: Double, gamma: Double) -> Double {
                let raw = lo + (hi - lo) * pow(input, gamma)
                let clamped = max(0, min(cap, raw))
                if adjustment.quantizationLevels < 256 {
                    return floor(clamped * Double(levels)) / Double(levels)
                }
                return clamped
            }
            red[index] = value(lo: params.rLo, hi: params.rHi, gamma: params.rGamma)
            green[index] = value(lo: params.gLo, hi: params.gHi, gamma: params.gGamma)
            blue[index] = value(lo: params.bLo, hi: params.bHi, gamma: params.bGamma)
        }

        // Inversion is already expressed by swapping lo/hi in channelParams; flipping
        // the finished table again would cancel it out.
        return (red, green, blue)
    }

    private struct ChannelParams {
        var rLo = 0.0
        var rHi = 1.0
        var rGamma = 1.0
        var gLo = 0.0
        var gHi = 1.0
        var gGamma = 1.0
        var bLo = 0.0
        var bHi = 1.0
        var bGamma = 1.0
    }

    private static func channelParams(_ adjustment: GammaAdjustment) -> ChannelParams {
        let globalGamma = pow(2.0, -adjustment.gamma / 100.0)
        let redGamma = globalGamma * pow(2.0, -adjustment.redGamma / 100.0)
        let greenGamma = globalGamma * pow(2.0, -adjustment.greenGamma / 100.0)
        let blueGamma = globalGamma * pow(2.0, -adjustment.blueGamma / 100.0)

        let globalGain = max(0, 1 + adjustment.gain / 100.0)
        let redGain = max(0, globalGain * (1 + adjustment.redGain / 100.0))
        let greenGain = max(0, globalGain * (1 + adjustment.greenGain / 100.0))
        let blueGain = max(0, globalGain * (1 + adjustment.blueGain / 100.0))

        let temperature = colorTemperatureFactors(adjustment.colorTemperature)
        let contrastShift = adjustment.contrast / 250.0

        var params = ChannelParams()
        params.rLo = -contrastShift
        params.gLo = -contrastShift
        params.bLo = -contrastShift
        params.rHi = redGain * temperature.r + contrastShift
        params.gHi = greenGain * temperature.g + contrastShift
        params.bHi = blueGain * temperature.b + contrastShift
        params.rGamma = redGamma
        params.gGamma = greenGamma
        params.bGamma = blueGamma

        if adjustment.isInverted {
            swap(&params.rLo, &params.rHi)
            swap(&params.gLo, &params.gHi)
            swap(&params.bLo, &params.bHi)
        }
        return params
    }

    /// Tanner Helland's approximation, normalized so 6500 K is (1, 1, 1).
    /// Positive slider values warm the display; negative values cool it.
    public static func colorTemperatureFactors(_ slider: Double) -> (r: Double, g: Double, b: Double) {
        guard slider != 0 else { return (1, 1, 1) }
        let kelvin: Double
        if slider > 0 {
            kelvin = 6500 - slider / 100 * 4500
        } else {
            kelvin = 6500 - slider / 100 * 5500
        }
        let (r, g, b) = kelvinToRGB(kelvin)
        let (nr, ng, nb) = kelvinToRGB(6500)
        return (nr > 0 ? r / nr : r, ng > 0 ? g / ng : g, nb > 0 ? b / nb : b)
    }

    public static func kelvinToRGB(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let temperature = max(1000, min(40000, kelvin)) / 100
        let red: Double
        if temperature <= 66 {
            red = 1
        } else {
            red = max(0, min(1, 1.292936186 * pow(temperature - 60, -0.1332047592)))
        }
        let green: Double
        if temperature <= 66 {
            green = max(0, min(1, 0.390081579 * log(temperature) - 0.631841444))
        } else {
            green = max(0, min(1, 1.129890861 * pow(temperature - 60, -0.0755148492)))
        }
        let blue: Double
        if temperature >= 66 {
            blue = 1
        } else if temperature <= 19 {
            blue = 0
        } else {
            blue = max(0, min(1, 0.543206789 * log(temperature - 10) - 1.196254089))
        }
        return (red, green, blue)
    }
}
