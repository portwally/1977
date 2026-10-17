import SwiftUI
import Combine
import UniformTypeIdentifiers
import AVFoundation

/// Which Apple II output mode(s) to include on the exported disk.
/// Six combinations: TEXT 40 / 80 / both, and color LORES 40 / DLORES 80 /
/// both. Each frame in TEXT mode is 1 KB (40-col) or 2 KB (80-col) of
/// screen-page-1 bytes; each LORES frame is the same size (LORES reuses
/// text page 1).
enum VideoColMode: String, CaseIterable, Identifiable {
    case col40     = "40-col TEXT"
    case col80     = "80-col TEXT"
    case both      = "Both TEXT (40 + 80)"
    case lores40   = "40-col LORES (color)"
    case dlores80  = "80-col DLORES (color)"
    case bothLores = "Both LORES (40 + 80)"

    var id: String { rawValue }

    var includes40:        Bool { self == .col40     || self == .both }
    var includes80:        Bool { self == .col80     || self == .both }
    var includesLores40:   Bool { self == .lores40   || self == .bothLores }
    var includesDlores80:  Bool { self == .dlores80  || self == .bothLores }

    /// True if any LORES variant is active (used to swap the preview
    /// canvas and hide the character-ramp UI).
    var isLores: Bool { includesLores40 || includesDlores80 }

    /// Total bytes-per-frame against the disk-capacity calculation.
    /// LORES uses the same 1 KB / 2 KB sizes as TEXT (same memory page).
    var bytesPerFrame: Int {
        var total = 0
        if includes40        { total += 1024 }
        if includes80        { total += 2048 }
        if includesLores40   { total += 1024 }
        if includesDlores80  { total += 2048 }
        return total
    }
}

/// Drives the video-converter window: video loading, frame extraction,
/// per-frame ASCII conversion, preview scrubbing, and disk export.
@MainActor
final class VideoConverterViewModel: ObservableObject {

    // MARK: - Inputs

    @Published var videoURL:        URL?
    @Published var videoName:       String  = ""
    @Published var videoDuration:   Double  = 0      // seconds

    @Published var targetFPS:       Double  = 4      // 1, 2, 4, 6, 8
    @Published var diskFormat:      DiskImageFormat = .po140
    @Published var colMode:         VideoColMode    = .both

    @Published var settings:        ConversionSettings = {
        var s = ConversionSettings()
        s.platform = .appleII40
        return s
    }()
    @Published var useCustomRamp:   Bool    = false
    @Published var customRampText:  String  = " .:-=+*#%@"

    @Published var previewFrameIndex: Int = 0
    @Published var previewUses80:    Bool = false    // toggle between 40/80 preview
    @Published var isPlaying:        Bool = false    // in-app preview playback

    // MARK: - Outputs / state

    @Published var rawFrames:       [NSImage]          = []
    @Published var frames40:        [ASCIIResult]      = []  // text 40-col
    @Published var frames80:        [ASCIIResult]      = []  // text 80-col
    @Published var framesLo:        [LoresFrameResult] = []  // LORES 40
    @Published var framesDl:        [LoresFrameResult] = []  // DLORES 80

    @Published var isExtracting:    Bool   = false
    @Published var isConverting:    Bool   = false
    @Published var isExporting:     Bool   = false
    @Published var progress:        Double = 0     // 0–1
    @Published var statusMessage:   String = ""
    @Published var errorMessage:    String?

    // MARK: - Computed

    /// True while any background job owns the frame buffers. New loads,
    /// re-extracts and exports are refused until it clears.
    var isBusy: Bool { isExtracting || isConverting || isExporting }

    /// Frames the chosen disk format can hold for the selected mode(s).
    var maxFrames: Int {
        VideoDiskExporter.maxFrames(format: diskFormat,
                                    has40: colMode.includes40,
                                    has80: colMode.includes80,
                                    hasLo: colMode.includesLores40,
                                    hasDl: colMode.includesDlores80)
    }

    /// Frames we'll actually export (whichever is smaller).
    var frameCount: Int {
        min(rawFrames.count, maxFrames)
    }

    /// Estimated playback duration in seconds.
    var estimatedDuration: Double {
        guard targetFPS > 0 else { return 0 }
        return Double(frameCount) / targetFPS
    }

    /// Frames-by-bytes approximation for the disk-usage readout.
    var diskUsageBytes: Int {
        frameCount * colMode.bytesPerFrame
    }

    var effectiveRamp: CharacterRamp {
        if useCustomRamp {
            let chars = Array(customRampText).filter { !$0.isNewline }
            return CharacterRamp(id: "custom", displayName: "Custom",
                                 characters: chars.isEmpty ? [" "] : chars)
        }
        return settings.ramp
    }

    /// Discriminated result of `previewFrame` — either a text grid or a
    /// LORES color grid, depending on which output mode is active.
    enum PreviewFrame {
        case text(ASCIIResult)
        case lores(LoresFrameResult)
    }

    /// Frame to render in the preview pane. Picks text or LORES based
    /// on `colMode`; within that, the 40 ↔ 80 toggle (`previewUses80`)
    /// picks which sub-mode to show.
    var previewFrame: PreviewFrame? {
        if colMode.isLores {
            let list = previewUses80 ? framesDl : framesLo
            guard !list.isEmpty else { return nil }
            let idx = min(max(0, previewFrameIndex), list.count - 1)
            return .lores(list[idx])
        } else {
            let list = previewUses80 ? frames80 : frames40
            guard !list.isEmpty else { return nil }
            let idx = min(max(0, previewFrameIndex), list.count - 1)
            return .text(list[idx])
        }
    }

    /// The settings to pass to ASCIICanvas — same as `settings` but
    /// platform reflects the preview toggle so the canvas uses the
    /// right font / cell math for whatever it's drawing.
    var previewSettings: ConversionSettings {
        var s = settings
        s.platform = previewUses80 ? .appleII80 : .appleII40
        return s
    }

    // MARK: - Reactive plumbing

    private var cancellables = Set<AnyCancellable>()
    private var reconvertTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    /// Set when settings change while frames are still being extracted;
    /// the finished frames are re-converted once extraction ends.
    private var reconvertPending = false

    init() {
        // Debounced re-convert on any settings change once frames are loaded.
        $settings
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.reconvertExistingFrames() }
            .store(in: &cancellables)

        $useCustomRamp
            .dropFirst()
            .sink { [weak self] _ in self?.reconvertExistingFrames() }
            .store(in: &cancellables)

        $customRampText
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                if self.useCustomRamp { self.reconvertExistingFrames() }
            }
            .store(in: &cancellables)

        $colMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self else { return }
                // Snap the preview 40/80 toggle to whichever side is on
                // disk for this mode — works for both TEXT and LORES.
                let has40Side = mode.includes40 || mode.includesLores40
                let has80Side = mode.includes80 || mode.includesDlores80
                if !has80Side { self.previewUses80 = false }
                if !has40Side { self.previewUses80 = true  }
                // **Pass the new mode explicitly.** `@Published` publishes
                // in willSet, so inside this sink `self.colMode` is still
                // the OLD value. Reading it inside reconvert would produce
                // frames for the wrong mode and leave the new one empty.
                self.reconvertExistingFrames(overrideMode: mode)
            }
            .store(in: &cancellables)
    }

    // MARK: - Video loading

    /// Show the open panel and load the chosen file. Restricted to MP4
    /// and MOV containers — everything else (MKV, WebM, FLV, etc.) is
    /// greyed out, since AVFoundation on macOS can't reliably decode
    /// those without third-party codecs.
    func openVideoFilePicker() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes     = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.message                 = "Choose an MP4 or MOV file."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.loadVideo(from: url) }
        }
    }

    /// Drop-handler version: accept the first .fileURL provider.
    func loadDroppedProviders(_ providers: [NSItemProvider]) {
        guard !isBusy, let p = providers.first else { return }
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] item, _ in
                let url: URL? = {
                    if let u = item as? URL { return u }
                    if let d = item as? Data { return URL(dataRepresentation: d, relativeTo: nil) }
                    if let s = item as? String { return URL(string: s) }
                    return nil
                }()
                guard let url else { return }
                Task { @MainActor in await self?.loadVideo(from: url) }
            }
        }
    }

    func loadVideo(from url: URL) async {
        guard !isBusy else { return }
        AppDebugLog.shared.clear()
        appLog("VM [v4]: loadVideo START url=\(url.lastPathComponent)")
        videoURL  = url
        videoName = url.deletingPathExtension().lastPathComponent

        do {
            videoDuration = try await VideoFrameExtractor.duration(of: url)
            appLog("VM [v4]: loadVideo got videoDuration=\(String(format: "%.3f", videoDuration))s from duration(of:)")
            statusMessage = "Loaded: \(videoName) — \(formatDuration(videoDuration))"
            rawFrames     = []
            frames40      = []
            frames80      = []
            framesLo      = []
            framesDl      = []
            previewFrameIndex = 0
            // Kick off extraction + conversion automatically.
            await processFrames()
        } catch {
            appLog("VM [v4]: loadVideo FAILED \(error.localizedDescription)")
            errorMessage = "Could not load video: \(error.localizedDescription)"
        }
    }

    // MARK: - Processing pipeline

    /// Stream frames from the loaded video and convert each one as it
    /// arrives. Single-pass: each frame is extracted, immediately turned
    /// into ASCIIResult(s), then released. Memory usage stays bounded
    /// (~300 KB live × small backbuffer) regardless of video length.
    func processFrames() async {
        guard let url = videoURL, !isExtracting, !isConverting, !isExporting else { return }

        // Stop any preview playback before we wipe the frame arrays.
        stopPlayback()

        isExtracting  = true
        isConverting  = true
        progress      = 0
        statusMessage = "Extracting frames…"

        let fps      = targetFPS
        let cap      = max(1, maxFrames)
        let ramp     = effectiveRamp
        var s40      = settings; s40.platform = .appleII40
        var s80      = settings; s80.platform = .appleII80
        let want40   = colMode.includes40
        let want80   = colMode.includes80
        let wantLo   = colMode.includesLores40
        let wantDl   = colMode.includesDlores80
        let snapshot = settings   // for LORES (platform agnostic; uses Apple II screen rect)

        rawFrames         = []
        frames40          = []
        frames80          = []
        framesLo          = []
        framesDl          = []
        previewFrameIndex = 0

        var newRaw: [NSImage]          = []
        var new40:  [ASCIIResult]      = []
        var new80:  [ASCIIResult]      = []
        var newLo:  [LoresFrameResult] = []
        var newDl:  [LoresFrameResult] = []
        var seenTotal = 0

        // Compute the expected frame count from the already-verified
        // video duration so the status bar can show it before extraction
        // starts (and so we don't depend on AVFoundation re-loading the
        // duration consistently inside the extractor).
        appLog("VM [v4]: processFrames START url=\(url.lastPathComponent)")
        appLog("VM [v4]: diskFormat=\(diskFormat.rawValue) maxFramesForDisk=\(cap) — IGNORED for extraction")
        // **Decouple extraction from disk format.** Disk size is an
        // export-time decision; extracting only `disk.maxFrames` frames
        // means switching to a bigger disk later requires re-opening the
        // file. Instead extract by source-video length, capped at a
        // generous absolute ceiling so a 4-hour rip doesn't OOM.
        let absoluteCap = 30_000
        let extractionCap = min(max(1, Int(floor(videoDuration * fps)) + 1), absoluteCap)
        appLog("VM [v4]: videoDuration=\(String(format: "%.3f", videoDuration))s fps=\(fps) " +
               "extractionCap=\(extractionCap) (source-bound, NOT disk-bound) colMode=\(colMode.rawValue)")

        let expectedTotal = extractionCap
        appLog("VM [v4]: expectedTotal = \(expectedTotal) frames")

        statusMessage = "Processing from \(String(format: "%.1f", videoDuration))s source → \(expectedTotal) frames…"

        do {
            appLog("VM [v4]: calling streamFrames(durationOverride: \(videoDuration), maxFrames: \(extractionCap))")
            let stream = VideoFrameExtractor.streamFrames(
                from: url,
                fps: fps,
                maxFrames: extractionCap,
                durationOverride: videoDuration
            )
            for try await chunk in stream {
                if Task.isCancelled { break }
                seenTotal = chunk.total

                // Conversion runs OFF the main actor. Tries the Metal GPU
                // path first (text + LORES); falls back to CPU per-mode
                // if Metal isn't available. Returns up to 4 grids per
                // frame: 40/80 text + 40/80 LORES.
                let img = chunk.image
                let conv: (t40: ASCIIResult?, t80: ASCIIResult?,
                           lo:  LoresFrameResult?, dl: LoresFrameResult?) =
                    await Task.detached(priority: .userInitiated) {
                    let metal = MetalASCIIConverter.shared
                    var t40: ASCIIResult?     = nil
                    var t80: ASCIIResult?     = nil
                    var lo:  LoresFrameResult? = nil
                    var dl:  LoresFrameResult? = nil

                    // Text path (40 / 80) — Metal with CPU fallback.
                    if want40 || want80 {
                        if let m = metal {
                            (t40, t80) = m.convertBoth(
                                image: img,
                                settings40: want40 ? s40 : nil,
                                settings80: want80 ? s80 : nil,
                                customRamp: ramp
                            )
                        }
                        if want40, t40 == nil {
                            t40 = ASCIIConverter.convert(image: img, settings: s40, customRamp: ramp)
                        }
                        if want80, t80 == nil {
                            t80 = ASCIIConverter.convert(image: img, settings: s80, customRamp: ramp)
                        }
                    }

                    // LORES path (40 / 80) — Metal with CPU fallback.
                    if wantLo || wantDl {
                        if let m = metal {
                            (lo, dl) = m.convertLores(
                                image: img,
                                lores40:  wantLo,
                                dlores80: wantDl,
                                settings: snapshot
                            )
                        }
                        if wantLo, lo == nil {
                            lo = LoresConverter.convert(image: img, cols: 40, settings: snapshot)
                        }
                        if wantDl, dl == nil {
                            dl = LoresConverter.convert(image: img, cols: 80, settings: snapshot)
                        }
                    }

                    return (t40, t80, lo, dl)
                }.value

                newRaw.append(img)
                if let r = conv.t40 { new40.append(r) }
                if let r = conv.t80 { new80.append(r) }
                if let r = conv.lo  { newLo.append(r) }
                if let r = conv.dl  { newDl.append(r) }

                let done = chunk.index + 1
                progress = Double(done) / Double(chunk.total)
                statusMessage = "Processing frame \(done) / \(chunk.total)…"
                // Log only sparsely so we don't drown the debug panel —
                // the per-chunk logs in the extractor already give us
                // the per-30s granularity.
                if done == 1 || done % 100 == 0 {
                    appLog("VM [v4]: consumed frame \(done) / chunk.total=\(chunk.total)")
                }

                // Publish partial results every 25 frames so the preview
                // can scrub through what's been processed so far.
                if done % 25 == 0 || done == chunk.total {
                    rawFrames = newRaw
                    frames40  = new40
                    frames80  = new80
                    framesLo  = newLo
                    framesDl  = newDl
                }
            }
        } catch {
            errorMessage  = error.localizedDescription
        }

        rawFrames     = newRaw
        frames40      = new40
        frames80      = new80
        framesLo      = newLo
        framesDl      = newDl
        isExtracting  = false
        isConverting  = false
        progress      = 1.0

        let count = newRaw.count
        let effectiveTotal = max(seenTotal, expectedTotal)
        let dropped = max(0, effectiveTotal - count)
        appLog("VM [v4]: processFrames END count=\(count) seenTotal=\(seenTotal) expectedTotal=\(expectedTotal) effectiveTotal=\(effectiveTotal) dropped=\(dropped)")
        if dropped > 0 {
            statusMessage = "Ready · \(count) / \(effectiveTotal) frames (lost \(dropped)) · " +
                            "\(String(format: "%.1f", estimatedDuration)) s playback"
        } else {
            statusMessage = "Ready · \(count) frame\(count == 1 ? "" : "s") · " +
                            "\(String(format: "%.1f", estimatedDuration)) s playback"
        }
        previewFrameIndex = 0

        if reconvertPending {
            reconvertPending = false
            reconvertExistingFrames()
        }
    }

    /// Re-run conversion on the already-extracted `rawFrames` without
    /// touching AVFoundation. Triggered when settings change. Produces
    /// both text and LORES grids as needed by the active mode.
    ///
    /// `overrideMode` — pass the new mode explicitly when called from
    /// the `$colMode` sink. Combine's `@Published` publishes in willSet,
    /// so reading `self.colMode` inside that sink yields the *old* value;
    /// the override is the only reliable way to know what mode the user
    /// actually wants right now.
    private func reconvertExistingFrames(overrideMode: VideoColMode? = nil) {
        // Mid-extraction `rawFrames` is only partial; redo the conversion
        // once it's complete so the new settings apply to every frame.
        if isExtracting { reconvertPending = true; return }
        guard !rawFrames.isEmpty else { return }
        reconvertTask?.cancel()

        let mode     = overrideMode ?? colMode
        let raw      = rawFrames
        let ramp     = effectiveRamp
        var s40      = settings; s40.platform = .appleII40
        var s80      = settings; s80.platform = .appleII80
        let snapshot = settings
        let want40   = mode.includes40
        let want80   = mode.includes80
        let wantLo   = mode.includesLores40
        let wantDl   = mode.includesDlores80
        appLog("VM [v4]: reconvert START mode=\(mode.rawValue) want40=\(want40) want80=\(want80) wantLo=\(wantLo) wantDl=\(wantDl)")

        isConverting  = true
        progress      = 0
        statusMessage = "Re-converting \(raw.count) frame\(raw.count == 1 ? "" : "s")…"

        reconvertTask = Task {
            let result: (f40: [ASCIIResult], f80: [ASCIIResult],
                         fLo: [LoresFrameResult], fDl: [LoresFrameResult]) =
                await Task.detached(priority: .userInitiated) {
                var out40: [ASCIIResult]      = []
                var out80: [ASCIIResult]      = []
                var outLo: [LoresFrameResult] = []
                var outDl: [LoresFrameResult] = []
                if want40 { out40.reserveCapacity(raw.count) }
                if want80 { out80.reserveCapacity(raw.count) }
                if wantLo { outLo.reserveCapacity(raw.count) }
                if wantDl { outDl.reserveCapacity(raw.count) }

                let metal = MetalASCIIConverter.shared

                for (i, img) in raw.enumerated() {
                    if Task.isCancelled { return (out40, out80, outLo, outDl) }

                    // Text path
                    if want40 || want80 {
                        var t40: ASCIIResult? = nil
                        var t80: ASCIIResult? = nil
                        if let m = metal {
                            (t40, t80) = m.convertBoth(
                                image: img,
                                settings40: want40 ? s40 : nil,
                                settings80: want80 ? s80 : nil,
                                customRamp: ramp
                            )
                        }
                        if want40, t40 == nil {
                            t40 = ASCIIConverter.convert(image: img, settings: s40, customRamp: ramp)
                        }
                        if want80, t80 == nil {
                            t80 = ASCIIConverter.convert(image: img, settings: s80, customRamp: ramp)
                        }
                        if let r = t40 { out40.append(r) }
                        if let r = t80 { out80.append(r) }
                    }
                    // LORES path
                    if wantLo || wantDl {
                        var lo: LoresFrameResult? = nil
                        var dl: LoresFrameResult? = nil
                        if let m = metal {
                            (lo, dl) = m.convertLores(
                                image: img,
                                lores40: wantLo,
                                dlores80: wantDl,
                                settings: snapshot
                            )
                        }
                        if wantLo, lo == nil {
                            lo = LoresConverter.convert(image: img, cols: 40, settings: snapshot)
                        }
                        if wantDl, dl == nil {
                            dl = LoresConverter.convert(image: img, cols: 80, settings: snapshot)
                        }
                        if let r = lo { outLo.append(r) }
                        if let r = dl { outDl.append(r) }
                    }

                    let p = Double(i + 1) / Double(raw.count)
                    await MainActor.run { self.progress = p }
                }
                return (out40, out80, outLo, outDl)
            }.value

            if Task.isCancelled { return }
            frames40 = result.f40
            frames80 = result.f80
            framesLo = result.fLo
            framesDl = result.fDl
            isConverting  = false
            progress      = 1.0
            statusMessage = "Ready · \(frameCount) frame\(frameCount == 1 ? "" : "s")"
            appLog("VM [v4]: reconvert END t40=\(result.f40.count) t80=\(result.f80.count) lo=\(result.fLo.count) dl=\(result.fDl.count)")
        }
    }

    // MARK: - Export

    func exportDisk() {
        guard !rawFrames.isEmpty else {
            errorMessage = "Load and process a video first."
            return
        }
        guard !isExtracting, !isConverting, !isExporting else { return }
        let panel = NSSavePanel()
        let ext   = diskFormat.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "\(videoName.isEmpty ? "video" : videoName).\(ext)"

        // Trim each list to the disk capacity before exporting.
        let cap = frameCount
        let f40:  [ASCIIResult]?      = colMode.includes40
            ? Array(frames40.prefix(cap)) : nil
        let f80:  [ASCIIResult]?      = colMode.includes80
            ? Array(frames80.prefix(cap)) : nil
        let fLo:  [LoresFrameResult]? = colMode.includesLores40
            ? Array(framesLo.prefix(cap)) : nil
        let fDl:  [LoresFrameResult]? = colMode.includesDlores80
            ? Array(framesDl.prefix(cap)) : nil
        let fps  = targetFPS
        let fmt  = diskFormat

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                self.isExporting  = true
                self.statusMessage = "Writing disk image…"
                do {
                    try await VideoDiskExporter.export(
                        frames40: f40, frames80: f80,
                        framesLores: fLo, framesDlores: fDl,
                        fps: fps, format: fmt, to: url
                    )
                    self.statusMessage = "Exported: \(url.lastPathComponent)"
                } catch {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = ""
                }
                self.isExporting = false
            }
        }
    }

    // MARK: - In-app playback

    /// Start advancing `previewFrameIndex` at `targetFPS`, looping at the
    /// end. Uses a single async Task with `Task.sleep` rather than a Timer
    /// so everything stays main-actor isolated and cancellation is clean.
    /// Returns the count of frames in the currently-visible preview
    /// list, picking between text/LORES + 40/80 sides based on the VM
    /// state — single source of truth for playback and scrubbing.
    private var visibleFrameCount: Int {
        if colMode.isLores {
            return (previewUses80 ? framesDl : framesLo).count
        } else {
            return (previewUses80 ? frames80 : frames40).count
        }
    }

    func startPlayback() {
        let count = visibleFrameCount
        guard count > 0, targetFPS > 0 else { return }

        // If we're at the end, restart from 0.
        if previewFrameIndex >= count - 1 { previewFrameIndex = 0 }

        playbackTask?.cancel()
        isPlaying = true

        let interval = max(0.0, 1.0 / targetFPS)
        let nanos    = UInt64(interval * 1_000_000_000)

        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.isPlaying == true {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                guard let self else { return }
                let n = self.visibleFrameCount
                guard n > 0 else { self.stopPlayback(); return }
                let next = self.previewFrameIndex + 1
                self.previewFrameIndex = next >= n ? 0 : next
            }
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    func togglePlayback() {
        if isPlaying { stopPlayback() } else { startPlayback() }
    }

    // MARK: - Helpers

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s.rounded())
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}
