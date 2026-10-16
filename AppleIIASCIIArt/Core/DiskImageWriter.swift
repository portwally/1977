import Foundation

/// Apple II disk-image formats supported by the video exporter.
///
/// All four formats produce a bootable disk. `VideoDiskExporter` builds
/// each volume from scratch via `ProDOSWriter.createDiskImage()` (so the
/// bitmap is correctly sized — including the 16-block bitmap a 32 MB
/// volume needs), then injects the boot blocks, PRODOS, and BASIC.SYSTEM
/// extracted from the bundled 140 KB template so the disk boots into
/// ProDOS exactly the way a stock-system disk would.
enum DiskImageFormat: String, CaseIterable, Identifiable {
    case po140  = "140 KB floppy (.po)"
    case po800  = "800 KB floppy (.po)"
    case twoImg = "32 MB hard disk (.2mg)"
    case hdv    = "32 MB hard disk (.hdv)"

    var id: String { rawValue }

    /// Filename extension chosen by the save panel.
    var fileExtension: String {
        switch self {
        case .po140, .po800: return "po"
        case .twoImg:        return "2mg"
        case .hdv:           return "hdv"
        }
    }

    /// Total 512-byte ProDOS blocks for this format.
    /// 65 535 blocks = the maximum ProDOS-8 volume size (just under 32 MB).
    var totalBlocks: Int {
        switch self {
        case .po140:  return 280
        case .po800:  return 1_600
        case .twoImg: return 65_535
        case .hdv:    return 65_535
        }
    }

}

/// Wraps raw ProDOS block data in the requested container format and
/// writes the result to `url`. `.po` and `.hdv` are byte-identical to
/// the raw ProDOS stream — they only differ by extension. `.2mg`
/// prepends a 64-byte "2IMG" header that emulators use to identify
/// the format and image geometry.
enum DiskImageWriter {

    /// Format the 64-byte 2IMG header for `proDOSData` containing exactly
    /// `blocks` ProDOS blocks.
    ///
    /// Spec: https://apple2.org.za/gswv/a2zine/Docs/DiskImage_2MG_Info.txt
    ///
    /// Layout (all little-endian):
    ///   00  4    "2IMG" magic
    ///   04  4    Creator ID (4 ASCII chars, "1977")
    ///   08  2    Header length (64)
    ///   0A  2    Version (1)
    ///   0C  4    Image format (1 = ProDOS-order)
    ///   10  4    Flags (0)
    ///   14  4    # of ProDOS blocks
    ///   18  4    Offset to disk data (= 64, right after this header)
    ///   1C  4    Length of disk data (blocks × 512)
    ///   20  4    Offset to comment (0 if none)
    ///   24  4    Length of comment
    ///   28  4    Offset to creator-specific data (0 if none)
    ///   2C  4    Length of creator data
    ///   30  16   Reserved (must be 0)
    static func twoImgHeader(blocks: Int) -> Data {
        var h = Data(count: 64)

        // 00-03: "2IMG" magic
        h[0] = 0x32; h[1] = 0x49; h[2] = 0x4D; h[3] = 0x47

        // 04-07: Creator ID ("1977")
        h[4] = 0x31; h[5] = 0x39; h[6] = 0x37; h[7] = 0x37

        // 08-09: Header length (LE16) = 64
        h[8] = 0x40; h[9] = 0x00

        // 0A-0B: Version (LE16) = 1
        h[10] = 0x01; h[11] = 0x00

        // 0C-0F: Image format (LE32) = 1 (ProDOS-order)
        h[12] = 0x01; h[13] = 0x00; h[14] = 0x00; h[15] = 0x00

        // 10-13: Flags (LE32) = 0
        h[16] = 0; h[17] = 0; h[18] = 0; h[19] = 0

        // 14-17: # ProDOS blocks (LE32)
        let nb = UInt32(blocks)
        h[20] = UInt8( nb        & 0xFF)
        h[21] = UInt8((nb >> 8 ) & 0xFF)
        h[22] = UInt8((nb >> 16) & 0xFF)
        h[23] = UInt8((nb >> 24) & 0xFF)

        // 18-1B: Offset to disk data (LE32) = 64
        h[24] = 0x40; h[25] = 0x00; h[26] = 0x00; h[27] = 0x00

        // 1C-1F: Length of disk data (LE32) = blocks × 512
        let dl = UInt32(blocks) * 512
        h[28] = UInt8( dl        & 0xFF)
        h[29] = UInt8((dl >> 8 ) & 0xFF)
        h[30] = UInt8((dl >> 16) & 0xFF)
        h[31] = UInt8((dl >> 24) & 0xFF)

        // 20-2F: comment offset/length + creator-data offset/length, all 0
        // 30-3F: reserved, must be 0
        // (Both already zeroed by `Data(count: 64)`.)
        return h
    }

    /// Wrap `proDOSData` in the given format and return the bytes that
    /// should be written to the user's chosen file URL.
    static func wrap(_ proDOSData: Data, format: DiskImageFormat) -> Data {
        switch format {
        case .po140, .po800, .hdv:
            return proDOSData
        case .twoImg:
            let blocks = proDOSData.count / 512
            return twoImgHeader(blocks: blocks) + proDOSData
        }
    }
}
