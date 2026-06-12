import Foundation

// MARK: - Color value types

/// 8-bit RGB color (0–255 per channel).
public struct RGB: Equatable, Hashable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = Int(r)
        self.g = Int(g)
        self.b = Int(b)
    }

    /// Three-element array form, matches the `color` library API used
    /// by the upstream JavaScript implementation.
    public var array: [Int] { [r, g, b] }
}

/// HSV/HSB color (h: 0–360, s: 0–100, b: 0–100).
public struct HSV: Equatable, Hashable, Sendable {
    public var h: Double
    public var s: Double
    public var b: Double

    public init(h: Double, s: Double, b: Double) {
        self.h = h
        self.s = s
        self.b = b
    }

    public var array: [Double] { [h, s, b] }
}

// MARK: - RGB <-> Int wire format

/// Yeelight's RGB wire format is a 24-bit integer
/// (`0xRRGGBB`, `0` … `16_777_215`).
public func rgbToInt(_ rgb: RGB) -> Int {
    let r = max(0, min(255, rgb.r))
    let g = max(0, min(255, rgb.g))
    let b = max(0, min(255, rgb.b))
    return (r << 16) | (g << 8) | b
}

public func intToRGB(_ value: Int) -> RGB {
    let v = max(0, min(0xFFFFFF, value))
    return RGB(
        r: (v >> 16) & 0xFF,
        g: (v >> 8) & 0xFF,
        b: v & 0xFF
    )
}

// MARK: - RGB <-> HSV

/// Convert RGB (0–255) to HSV (h: 0–360, s: 0–100, v: 0–100).
public func rgbToHSV(_ rgb: RGB) -> HSV {
    let r = Double(rgb.r) / 255.0
    let g = Double(rgb.g) / 255.0
    let b = Double(rgb.b) / 255.0

    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let delta = maxC - minC

    var h: Double = 0
    if delta != 0 {
        if maxC == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxC == g {
            h = ((b - r) / delta) + 2
        } else {
            h = ((r - g) / delta) + 4
        }
        h *= 60
        if h < 0 { h += 360 }
    }

    let s = maxC == 0 ? 0 : (delta / maxC) * 100
    let v = maxC * 100

    return HSV(h: h, s: s, b: v)
}

/// Convert HSV (h: 0–360, s: 0–100, v: 0–100) to RGB (0–255).
public func hsvToRGB(_ hsv: HSV) -> RGB {
    let h = hsv.h.truncatingRemainder(dividingBy: 360)
    let s = max(0, min(100, hsv.s)) / 100
    let v = max(0, min(100, hsv.b)) / 100

    let c = v * s
    let hh = h / 60
    let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c

    var r1: Double = 0, g1: Double = 0, b1: Double = 0
    switch hh {
    case 0..<1:    r1 = c; g1 = x; b1 = 0
    case 1..<2:    r1 = x; g1 = c; b1 = 0
    case 2..<3:    r1 = 0; g1 = c; b1 = x
    case 3..<4:    r1 = 0; g1 = x; b1 = c
    case 4..<5:    r1 = x; g1 = 0; b1 = c
    case 5..<6:    r1 = c; g1 = 0; b1 = x
    default:       r1 = 0; g1 = 0; b1 = 0
    }

    return RGB(
        r: Int(((r1 + m) * 255).rounded()),
        g: Int(((g1 + m) * 255).rounded()),
        b: Int(((b1 + m) * 255).rounded())
    )
}

// MARK: - Color temperature -> RGB

/// Color-temperature helpers. Replaces the `color-temp` npm package,
/// which uses the Tanner Helland approximation. The Yeelight spec
/// accepts CT in the range 1700 K … 6500 K; values outside that range
/// are clamped to match the upstream library's behavior.
public enum ColorTemp {
    public static func toRGB(kelvin: Int) -> RGB {
        let temp = max(1000, min(40000, Double(kelvin))) / 100.0

        // Red
        var r: Double
        if temp <= 66 {
            r = 255
        } else {
            r = 329.698727446 * pow(temp - 60, -0.1332047592)
        }
        r = clamp255(r)

        // Green
        var g: Double
        if temp <= 66 {
            g = 99.4708025861 * log(temp) - 161.1195681661
        } else {
            g = 288.1221695283 * pow(temp - 60, -0.0755148492)
        }
        g = clamp255(g)

        // Blue
        var b: Double
        if temp >= 66 {
            b = 255
        } else if temp <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(temp - 10) - 305.0447927307
        }
        b = clamp255(b)

        return RGB(r: Int(r), g: Int(g), b: Int(b))
    }

    private static func clamp255(_ value: Double) -> Double {
        return max(0, min(255, value))
    }
}
