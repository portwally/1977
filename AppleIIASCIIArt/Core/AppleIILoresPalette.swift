import Foundation
import SwiftUI

/// Apple II LORES / Double-LORES 16-color palette.
///
/// The colors below are the commonly-cited "NTSC artifact" values that
/// emulators (AppleWin, MAME, Virtual ][) and reproductions like the
/// IIgs RGB output approximate. Different references give slightly
/// different RGB values; these are tuned to look reasonable both in
/// our SwiftUI preview and as a quantization target for arbitrary
/// source video.
///
/// The byte order in screen memory is:
///   low nibble  (bits 0-3): top half of the cell
///   high nibble (bits 4-7): bottom half of the cell
/// A byte at offset N in text-page-1 layout therefore controls two
/// vertically-stacked 7-pixel-wide color blocks (LORES) or
/// 3.5-pixel-wide blocks (DLORES — even columns in AUX, odd in MAIN).
enum AppleIILoresPalette {

    /// Color index → (R, G, B). Indices 0-15.
    static let rgb: [(UInt8, UInt8, UInt8)] = [
        (0x00, 0x00, 0x00),   // 0  Black
        (0xDD, 0x00, 0x33),   // 1  Magenta
        (0x00, 0x00, 0x99),   // 2  Dark Blue
        (0xDD, 0x00, 0xDD),   // 3  Purple
        (0x00, 0x77, 0x22),   // 4  Dark Green
        (0x55, 0x55, 0x55),   // 5  Gray (dark)
        (0x22, 0x22, 0xFF),   // 6  Medium Blue
        (0x66, 0xAA, 0xFF),   // 7  Light Blue
        (0x88, 0x55, 0x00),   // 8  Brown
        (0xFF, 0x66, 0x00),   // 9  Orange
        (0xAA, 0xAA, 0xAA),   // 10 Gray (light)
        (0xFF, 0x99, 0x88),   // 11 Pink
        (0x11, 0xDD, 0x00),   // 12 Light Green
        (0xFF, 0xFF, 0x00),   // 13 Yellow
        (0x44, 0xFF, 0xAA),   // 14 Aqua
        (0xFF, 0xFF, 0xFF),   // 15 White
    ]

    /// SwiftUI `Color` for each palette index — used by `LoresCanvas`
    /// for the in-app preview.
    static let swiftColors: [Color] = rgb.map {
        Color(red:   Double($0.0) / 255.0,
              green: Double($0.1) / 255.0,
              blue:  Double($0.2) / 255.0)
    }

    /// CPU quantizer: find the palette index whose RGB has the smallest
    /// squared Euclidean distance to the input color. Plain (unweighted)
    /// distance — close enough for retro pixel-art quantization and ~5×
    /// faster than per-call perceptual conversion.
    @inlinable
    static func closestIndex(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        var bestIdx: UInt8 = 0
        var bestDist: Int = .max
        for i in 0..<16 {
            let p = rgb[i]
            let dr = Int(r) - Int(p.0)
            let dg = Int(g) - Int(p.1)
            let db = Int(b) - Int(p.2)
            let d  = dr * dr + dg * dg + db * db
            if d < bestDist { bestDist = d; bestIdx = UInt8(i) }
        }
        return bestIdx
    }
}

/// Result of converting one source frame to a LORES (or DLORES) grid:
/// a 2D array of palette indices (0–15), indexed `[row][col]`. The grid
/// is always **48 rows** (LORES vertical resolution) and either **40
/// cols** (LORES) or **80 cols** (DLORES).
struct LoresFrameResult {
    let cols:    Int
    let rows:    Int    // always 48
    let indices: [[UInt8]]   // [row][col], values 0..15
}
