import SwiftUI
import Combine
import UniformTypeIdentifiers
import CoreGraphics
import CoreText

@MainActor
class ConverterViewModel: ObservableObject {

    @Published var sourceImage: NSImage? = nil
    @Published var sourceImageName: String = ""
    @Published var settings: ConversionSettings = ConversionSettings()
    @Published var customRampText: String = " .:-=+*#%@"
    @Published var useCustomRamp: Bool = false
    @Published var result: ASCIIResult? = nil
    @Published var isConverting: Bool = false
    @Published var showExportSheet: Bool = false
    @Published var showCropTool: Bool = false
    @Published var cropRectNorm: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var errorMessage: String? = nil

    private var conversionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        // Debounce settings changes before triggering conversion
        $settings
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.convert() }
            .store(in: &cancellables)

        $customRampText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in
                if self?.useCustomRamp == true { self?.convert() }
            }
            .store(in: &cancellables)

        $useCustomRamp
            .dropFirst()
            .sink { [weak self] _ in self?.convert() }
            .store(in: &cancellables)

        $cropRectNorm
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.convert() }
            .store(in: &cancellables)
    }

    var effectiveRamp: CharacterRamp {
        if useCustomRamp {
            // Allow any Unicode character (block elements, PETSCII symbols, etc.)
            let chars = Array(customRampText).filter { !$0.isNewline }
            return CharacterRamp(id: "custom", displayName: "Custom", characters: chars.isEmpty ? [" "] : chars)
        }
        return settings.ramp
    }

    // MARK: - Image loading

    func openImageFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .bmp, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.loadImage(from: url)
            }
        }
    }

    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "Could not load image from \(url.lastPathComponent)."
            return
        }
        sourceImage = image
        sourceImageName = url.deletingPathExtension().lastPathComponent
        resetCrop()
        convert()
    }

    /// Strip from `customRampText` any character that the given font doesn't
    /// have a glyph for — those characters would otherwise render as '?'
    /// boxes in the new platform.
    func pruneCustomRampToFont(_ fontName: String) {
        let ctFont  = CTFontCreateWithName(fontName as CFString, 16, nil)
        let charset = CTFontCopyCharacterSet(ctFont) as CharacterSet
        let kept    = customRampText.unicodeScalars.filter { charset.contains($0) }
        let result  = String(String.UnicodeScalarView(kept))
        if result != customRampText { customRampText = result }
    }

    /// Initialise the crop rect to the largest centre-cropped box that
    /// matches the current platform's aspect ratio.
    func resetCrop() {
        guard let img = sourceImage else {
            cropRectNorm = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let imageAR = img.size.width / img.size.height
        let cropAR  = settings.platform.aspectRatio
        if imageAR > cropAR {
            let w = cropAR / imageAR
            cropRectNorm = CGRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
        } else {
            let h = imageAR / cropAR
            cropRectNorm = CGRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
    }

    func loadDroppedProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] item, _ in
                let url: URL? = {
                    if let directURL = item as? URL { return directURL }
                    if let data = item as? Data {
                        return URL(dataRepresentation: data, relativeTo: nil)
                    }
                    if let str = item as? String { return URL(string: str) }
                    return nil
                }()
                guard let url else { return }
                Task { @MainActor in self?.loadImage(from: url) }
            }
            return
        }

        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { [weak self] obj, _ in
                guard let image = obj as? NSImage else { return }
                Task { @MainActor in
                    self?.sourceImage = image
                    self?.sourceImageName = "dropped"
                    self?.resetCrop()
                    self?.convert()
                }
            }
        }
    }

    // MARK: - Conversion

    func convert() {
        guard let image = sourceImage else { return }
        conversionTask?.cancel()
        isConverting = true
        let snap    = settings
        let ramp    = effectiveRamp
        let cropped = croppedImage(image, norm: cropRectNorm)

        conversionTask = Task {
            let r = await Task.detached(priority: .userInitiated) {
                ASCIIConverter.convert(image: cropped, settings: snap, customRamp: ramp)
            }.value
            guard !Task.isCancelled else { return }
            self.result = r
            self.isConverting = false
        }
    }

    /// Returns a new NSImage cropped to the normalised rect (top-left origin).
    /// If the rect covers the whole image the original is returned unchanged.
    private func croppedImage(_ image: NSImage, norm: CGRect) -> NSImage {
        let tol: CGFloat = 0.001
        guard norm.minX > tol || norm.minY > tol ||
              norm.maxX < 1 - tol || norm.maxY < 1 - tol else { return image }

        let src  = image.size
        // NSImage draw coords have Y=0 at the bottom, so flip the normalised Y.
        let from = CGRect(
            x:      norm.minX        * src.width,
            y:     (1 - norm.maxY)   * src.height,
            width:  norm.width       * src.width,
            height: norm.height      * src.height
        )
        let out = NSImage(size: from.size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: from.size),
                   from: from, operation: .copy, fraction: 1.0)
        out.unlockFocus()
        return out
    }

    // MARK: - Export

    func exportText(appleII: Bool) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(sourceImageName.isEmpty ? "ascii_art" : sourceImageName).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                if appleII {
                    try TextExporter.saveAppleIIText(result, to: url)
                } else {
                    try TextExporter.saveMacText(result, to: url)
                }
            } catch {
                Task { @MainActor in self.errorMessage = error.localizedDescription }
            }
        }
    }

    func exportBASIC() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bas") ?? .plainText]
        panel.nameFieldStringValue = "\(sourceImageName.isEmpty ? "ascii_art" : sourceImageName).bas"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try BASICExporter.save(result, to: url)
            } catch {
                Task { @MainActor in self.errorMessage = error.localizedDescription }
            }
        }
    }

    func copyToClipboard() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.asPlainText(), forType: .string)
    }

    func exportPNG(scale: Int = 2) {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(sourceImageName.isEmpty ? "ascii_art" : sourceImageName).png"
        let snap = settings
        let res  = result
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let native  = snap.platform.screenSize
                let exportW = native.width  * CGFloat(scale)
                let exportH = native.height * CGFloat(scale)

                let canvas = ASCIICanvas(result: res, settings: snap)
                    .frame(width: exportW, height: exportH)

                let renderer = ImageRenderer(content: canvas)
                renderer.scale = 1.0   // frame already encodes the 4× size

                guard let cgImage = renderer.cgImage else {
                    self.errorMessage = "Could not render PNG image."
                    return
                }

                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    self.errorMessage = "Could not encode PNG data."
                    return
                }
                do {
                    try png.write(to: url)
                } catch {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func exportProDOSDisk() {
        guard let source = sourceImage else { return }
        let image = croppedImage(source, norm: cropRectNorm)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "po") ?? .data]
        panel.nameFieldStringValue = "\(sourceImageName.isEmpty ? "ascii_art" : sourceImageName).po"
        let snap = settings
        let ramp = effectiveRamp
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    // Convert at BOTH resolutions in parallel — the disk
                    // carries ART40.BAS/BIN/LOADER40.BAS plus ART80.BAS/BIN/
                    // LOADER80.BAS. The user's preview-column setting only
                    // affects the on-screen preview, not the disk contents.
                    var s40 = snap; s40.platform = .appleII40
                    var s80 = snap; s80.platform = .appleII80
                    let task40 = Task.detached(priority: .userInitiated) {
                        ASCIIConverter.convert(image: image, settings: s40, customRamp: ramp)
                    }
                    let task80 = Task.detached(priority: .userInitiated) {
                        ASCIIConverter.convert(image: image, settings: s80, customRamp: ramp)
                    }
                    let result40 = await task40.value
                    let result80 = await task80.value
                    try await DiskExporter.save(result40: result40,
                                                 result80: result80,
                                                 to: url)
                } catch {
                    await MainActor.run { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }
}
