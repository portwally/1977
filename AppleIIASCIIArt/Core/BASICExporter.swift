import Foundation

struct BASICExporter {

    /// Generates the Applesoft source text for the PRINT program.
    /// Used both for the .bas file export and for tokenizing onto a ProDOS disk.
    ///
    /// Two Apple-II display quirks are handled here:
    ///
    /// 1. **Double CR.** When a PRINT exactly fills the screen width (40 or 80
    ///    chars), the cursor auto-wraps to the next row — that's one CR. Then
    ///    PRINT itself emits a trailing CR — that's a second one, leaving a
    ///    blank line between every printed row. We suppress PRINT's CR with a
    ///    trailing `;` whenever the row fills the screen.
    ///
    /// 2. **Bottom-right scroll.** Printing the very last cell of row 24 (the
    ///    40th/80th char of the 24th row) auto-wraps past the bottom of the
    ///    screen and scrolls everything up by one line — wiping the top row.
    ///    For full-screen art we drop that one cell; HOME already left a space
    ///    in its place.
    static func generateSource(_ result: ASCIIResult) -> String {
        var lines: [String] = []
        var num = 10

        // The bundled ProDOS 2.0.3 template's BASIC.SYSTEM appears to leave
        // TRACE enabled across program transitions. Without an explicit
        // NOTRACE, Applesoft prints "#NN" before every line — which during a
        // 24-line PRINT loop interleaves "#50 #60 #70…" between every row of
        // art on screen.
        lines.append("5 NOTRACE")

        lines.append("\(num) HOME")
        num += 10

        if result.columns == 80 {
            lines.append("\(num) PR# 3")
            num += 10
            // PR# 3 (slot 3 firmware init) re-enables TRACE on this BASIC.SYSTEM.
            // 40-col path doesn't have this issue. Repeat NOTRACE after PR# 3.
            lines.append("\(num) NOTRACE")
            num += 10
        }

        let totalRows = result.grid.count
        let isFullScreen = totalRows >= 24

        for (idx, row) in result.grid.enumerated() {
            // Characters outside printable ASCII (Unicode block ramps,
            // etc.) don't exist on the Apple II — print them as spaces so
            // the row keeps its width.
            var rowStr = String(row.map { ch -> Character in
                guard let v = ch.asciiValue, v >= 0x20 && v < 0x7F else { return " " }
                return ch
            })
            let isLastRow = (idx == totalRows - 1)

            // Drop bottom-right cell on full-screen art to avoid scroll.
            if isLastRow && isFullScreen && rowStr.count >= result.columns {
                rowStr = String(rowStr.prefix(result.columns - 1))
            }

            let escaped = escapeForApplesoft(rowStr)

            // Suppress PRINT's trailing CR when the row already auto-wraps,
            // OR when it's the trimmed last row (where any CR would scroll).
            // Partial-width rows on non-full-screen art keep the CR so PRINT
            // advances to the next row.
            let fillsWidth   = rowStr.count >= result.columns
            let trimmedLast  = isLastRow && isFullScreen
            let suffix       = (fillsWidth || trimmedLast) ? ";" : ""

            lines.append("\(num) PRINT \"\(escaped)\"\(suffix)")
            num += 10
        }

        // Pause so the art stays visible until the user presses a key.
        lines.append("\(num) GET A$")
        num += 10
        lines.append("\(num) END")

        return lines.joined(separator: "\r")
    }

    static func save(_ result: ASCIIResult, to url: URL) throws {
        let source = generateSource(result)
        guard let data = source.data(using: .ascii) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url)
    }

    // Applesoft can't embed a literal " in a string — split around it
    private static func escapeForApplesoft(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\"; CHR$(34); \"")
    }

    enum ExportError: Error, LocalizedError {
        case encodingFailed
        var errorDescription: String? { "Failed to encode BASIC program as ASCII." }
    }
}
