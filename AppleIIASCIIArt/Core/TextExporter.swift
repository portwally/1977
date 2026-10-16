import Foundation

struct TextExporter {

    // Apple II plain text: 7-bit ASCII, CR (0x0D) line endings
    static func saveAppleIIText(_ result: ASCIIResult, to url: URL) throws {
        let text = result.asAppleIIText()
        // Replace (not drop) anything outside printable ASCII so rows
        // keep their width.
        let safe = String(text.map { c -> Character in
            guard let v = c.asciiValue, v >= 0x20 && v <= 0x7E || v == 0x0D else { return " " }
            return c
        })
        guard let data = safe.data(using: .ascii) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url)
    }

    // Mac plain text: LF line endings, UTF-8
    static func saveMacText(_ result: ASCIIResult, to url: URL) throws {
        try result.asPlainText().write(to: url, atomically: true, encoding: .utf8)
    }

    enum ExportError: Error, LocalizedError {
        case encodingFailed
        var errorDescription: String? { "Failed to encode text as ASCII." }
    }
}
