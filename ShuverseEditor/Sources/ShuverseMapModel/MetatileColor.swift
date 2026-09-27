import Foundation

/// Stable fake color for a metatile id. Tileset pixels replace this later.
public enum MetatileColor {
    public static func components(for metatileId: UInt16) -> (r: Float, g: Float, b: Float, a: Float) {
        let hue = (Float(metatileId) * 0.6180339887).truncatingRemainder(dividingBy: 1)
        let band = Float((Int(metatileId) / 17) % 3)
        let saturation = 0.48 + band * 0.12
        let value = min(0.72 + Float((Int(metatileId) / 5) % 2) * 0.18, 1)
        let rgb = hsvToRGB(h: hue < 0 ? hue + 1 : hue, s: saturation, v: value)
        return (rgb.0, rgb.1, rgb.2, 1)
    }

    private static func hsvToRGB(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        let sector = h * 6
        let index = Int(sector) % 6
        let fraction = sector - Float(Int(sector))
        let p = v * (1 - s)
        let q = v * (1 - fraction * s)
        let t = v * (1 - (1 - fraction) * s)
        switch index {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
