import Foundation

/// Builds a ProDOS disk image carrying a frame-by-frame ASCII video plus
/// a 6502 ML player. Two playback modes (40-col / 80-col) can ship on the
/// same disk; either or both may be supplied.
///
/// **Bootability for every size — including 32 MB.** The exporter always
/// builds a fresh ProDOS volume of the requested size (so the bitmap is
/// correctly sized — a 32 MB volume needs 16 bitmap blocks; a single
/// resized template would put the bitmap on top of PRODOS file data).
/// It then injects three things from the bundled `ProDOS_2_0_3.po`:
///
///   1. **Boot blocks** (blocks 0–1, 1024 bytes total). ProDOSWriter's
///      from-scratch boot code is incomplete — only the first 128 bytes
///      are filled. We overwrite blocks 0–1 with the template's full
///      boot code so the disk boots ProDOS as expected.
///   2. **PRODOS** (the ProDOS-8 kernel, type $FF). Added as a file —
///      ProDOSWriter's allocator places it at block 24+ rather than
///      block 8, but boot blocks find it by name in the directory, not
///      by hard-coded block.
///   3. **BASIC.SYSTEM** (the Applesoft shell, type $FF, aux $2000).
///      Same as above.
///
/// Disk layout (file order):
///
///     /VIDEO/
///       PRODOS, BASIC.SYSTEM       (from the bundled template)
///       STARTUP                    (Applesoft, auto-runs at boot — menu)
///       PLAY40                     (BAS wrapper → BRUN PLAY40.BIN)
///       PLAY40.BIN                 (ML player, $0900 — patched at
///                                   offsets 3-5 with frame count +
///                                   FPS delay)
///       FRAMES40                   (40-col frames concatenated)
///       PLAY80                     (BAS wrapper → BRUN PLAY80.BIN)
///       PLAY80.BIN                 (ML player; uses JSR $C300 itself
///                                   so PR# 3 isn't needed from BASIC)
///       FRAMES80                   (80-col frames concatenated)
struct VideoDiskExporter {

    enum DiskExportError: Error, LocalizedError {
        case templateMissing
        case templateUnreadable(String)
        case missingSystemFile(String)
        case write(String)
        case noFrames

        var errorDescription: String? {
            switch self {
            case .templateMissing:           return "Bundled ProDOS template image is missing."
            case .templateUnreadable(let m): return "Could not read ProDOS template: \(m)"
            case .missingSystemFile(let n):  return "ProDOS template is missing the \(n) file."
            case .write(let msg):            return "ProDOS write failed: \(msg)"
            case .noFrames:                  return "No frames to export."
            }
        }
    }

    // MARK: - Frame packing

    private static func packFrames40(_ frames: [ASCIIResult]) -> Data {
        var d = Data()
        d.reserveCapacity(frames.count * 1024)
        for f in frames { d.append(AppleIIScreenMemory.buildScreen40(grid: f.grid)) }
        return d
    }
    private static func packFrames80(_ frames: [ASCIIResult]) -> Data {
        var d = Data()
        d.reserveCapacity(frames.count * 2048)
        for f in frames { d.append(AppleIIScreenMemory.buildScreen80(grid: f.grid)) }
        return d
    }

    /// LORES variants — same byte counts as TEXT (LORES reuses text page 1).
    private static func packFramesLores(_ frames: [LoresFrameResult]) -> Data {
        var d = Data()
        d.reserveCapacity(frames.count * 1024)
        for f in frames { d.append(AppleIIScreenMemory.buildLores40(grid: f.indices)) }
        return d
    }
    private static func packFramesDlores(_ frames: [LoresFrameResult]) -> Data {
        var d = Data()
        d.reserveCapacity(frames.count * 2048)
        for f in frames { d.append(AppleIIScreenMemory.buildLores80(grid: f.indices)) }
        return d
    }

    // MARK: - Capacity

    /// PRODOS + BASIC.SYSTEM from the bundled template, read once. Their
    /// sizes feed the capacity calculation below.
    private static let systemFiles: (prodos: Data, basic: Data)? = {
        guard let url  = Bundle.main.url(forResource: "ProDOS_2_0_3", withExtension: "po"),
              let tpl  = try? Data(contentsOf: url),
              let p    = ProDOSWriter.shared.extractFileFromProDOS(tpl, fileName: "PRODOS"),
              let b    = ProDOSWriter.shared.extractFileFromProDOS(tpl, fileName: "BASIC.SYSTEM")
        else { return nil }
        return (p.data, b.data)
    }()

    /// Largest frame count per mode that fits on `format` with the given
    /// modes, counting every block the export writes (boot/directory/
    /// bitmap, PRODOS, BASIC.SYSTEM, STARTUP, each mode's wrapper +
    /// player + frames file including index blocks). Each frames file is
    /// also capped at the 16 MB ProDOS file-size limit.
    static func maxFrames(format: DiskImageFormat,
                          has40: Bool, has80: Bool,
                          hasLo: Bool, hasDl: Bool) -> Int {
        // Per-mode frame size, wrapper source and player binary.
        var modes: [(frameBytes: Int, wrapper: String, player: [UInt8])] = []
        if has40 { modes.append((1024, playWrapperSource(label: "", binName: "PLAY40.BIN"), VideoMLPlayer.play40Bytes)) }
        if has80 { modes.append((2048, playWrapperSource(label: "", binName: "PLAY80.BIN"), VideoMLPlayer.play80Bytes)) }
        if hasLo { modes.append((1024, playWrapperSource(label: "", binName: "PLAYLO.BIN"), VideoMLPlayer.playLoresBytes)) }
        if hasDl { modes.append((2048, playWrapperSource(label: "", binName: "PLAYDL.BIN"), VideoMLPlayer.playDloresBytes)) }
        guard !modes.isEmpty else { return 0 }

        let blocks = ProDOSWriter.blocksRequired(forFileSize:)
        let total  = format.totalBlocks

        // Fixed overhead: blocks 0-5 (boot + volume directory) + bitmap.
        var fixed = 6 + ((total + 4095) / 4096)
        if let sys = systemFiles {
            fixed += blocks(sys.prodos.count) + blocks(sys.basic.count)
        } else {
            fixed += 35 + 21   // ProDOS 2.0.3 sizes, if the template can't be read
        }
        // STARTUP — sized with 5-digit frame counts so it's an upper bound.
        let startup = startupSource(has40: has40, has80: has80, hasLo: hasLo, hasDl: hasDl,
                                    count40: 99_999, count80: 99_999,
                                    countLo: 99_999, countDl: 99_999)
        fixed += blocks(ApplesoftTokenizer.tokenize(startup).count)
        for m in modes {
            fixed += blocks(ApplesoftTokenizer.tokenize(m.wrapper).count) + blocks(m.player.count)
        }

        func fits(_ n: Int) -> Bool {
            fixed + modes.reduce(0) { $0 + blocks(n * $1.frameBytes) } <= total
        }

        // Upper bound: the ProDOS file-size limit and the player's 16-bit
        // frame counter.
        var hi = modes.map { ProDOSWriter.maxFileSize / $0.frameBytes }.min() ?? 0
        hi = min(hi, 0xFFFF)
        var lo = 0
        guard fits(0) else { return 0 }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: - Public entry point

    static func export(
        frames40: [ASCIIResult]?,
        frames80: [ASCIIResult]?,
        framesLores:  [LoresFrameResult]? = nil,
        framesDlores: [LoresFrameResult]? = nil,
        fps: Double,
        format: DiskImageFormat,
        to url: URL
    ) async throws {
        let hasAny = (frames40?.isEmpty     == false) ||
                     (frames80?.isEmpty     == false) ||
                     (framesLores?.isEmpty  == false) ||
                     (framesDlores?.isEmpty == false)
        guard hasAny else { throw DiskExportError.noFrames }

        // Read the bundled template up front — we need its boot blocks +
        // PRODOS + BASIC.SYSTEM regardless of the requested disk size.
        guard let templateURL = Bundle.main.url(forResource: "ProDOS_2_0_3", withExtension: "po") else {
            throw DiskExportError.templateMissing
        }
        let templateData: Data
        do { templateData = try Data(contentsOf: templateURL) }
        catch { throw DiskExportError.templateUnreadable(error.localizedDescription) }

        guard let prodos = ProDOSWriter.shared.extractFileFromProDOS(templateData, fileName: "PRODOS") else {
            throw DiskExportError.missingSystemFile("PRODOS")
        }
        guard let basicSys = ProDOSWriter.shared.extractFileFromProDOS(templateData, fileName: "BASIC.SYSTEM") else {
            throw DiskExportError.missingSystemFile("BASIC.SYSTEM")
        }

        // Build empty ProDOS volume of the requested size.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("1977_video_\(UUID().uuidString).po")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ProDOSWriter.shared.createDiskImage(
                at: tempURL,
                volumeName: "VIDEO",
                totalBlocks: format.totalBlocks
            ) { ok, msg in
                if ok { cont.resume() }
                else  { cont.resume(throwing: DiskExportError.write(msg)) }
            }
        }

        // Overwrite the fresh disk's stub boot blocks with the template's
        // real ProDOS boot code (1024 bytes — blocks 0 and 1).
        try injectBootBlocks(from: templateData, to: tempURL)

        // Add PRODOS and BASIC.SYSTEM as the first two files. The boot
        // blocks scan the volume directory looking for the file named
        // "PRODOS" — they don't care which physical block holds it.
        try await addFile(to: tempURL, name: "PRODOS",
                          data: prodos.data, type: prodos.fileType, aux: prodos.auxType)
        try await addFile(to: tempURL, name: "BASIC.SYSTEM",
                          data: basicSys.data, type: basicSys.fileType, aux: basicSys.auxType)

        // STARTUP launcher
        let startupSrc = startupSource(
            has40: frames40?.isEmpty     == false,
            has80: frames80?.isEmpty     == false,
            hasLo: framesLores?.isEmpty  == false,
            hasDl: framesDlores?.isEmpty == false,
            count40: frames40?.count     ?? 0,
            count80: frames80?.count     ?? 0,
            countLo: framesLores?.count  ?? 0,
            countDl: framesDlores?.count ?? 0
        )
        let startupTokens = ApplesoftTokenizer.tokenize(startupSrc)
        try await addFile(to: tempURL, name: "STARTUP",
                          data: startupTokens, type: 0xFC, aux: 0x0801)

        // 40-col TEXT files
        if let f40 = frames40, !f40.isEmpty {
            let play40 = ApplesoftTokenizer.tokenize(
                playWrapperSource(label: "40-COL VIDEO",
                                  binName: "PLAY40.BIN"))
            try await addFile(to: tempURL, name: "PLAY40",
                              data: play40, type: 0xFC, aux: 0x0801)

            let player40 = VideoMLPlayer.patched(
                VideoMLPlayer.play40Bytes,
                frameCount: f40.count, fps: fps, twoKBFrame: false
            )
            try await addFile(to: tempURL, name: "PLAY40.BIN",
                              data: player40, type: 0x06, aux: 0x0900)

            try await addFile(to: tempURL, name: "FRAMES40",
                              data: packFrames40(f40), type: 0x06, aux: 0x0000)
        }

        // 80-col TEXT files
        if let f80 = frames80, !f80.isEmpty {
            let play80 = ApplesoftTokenizer.tokenize(
                playWrapperSource(label: "80-COL VIDEO",
                                  binName: "PLAY80.BIN"))
            try await addFile(to: tempURL, name: "PLAY80",
                              data: play80, type: 0xFC, aux: 0x0801)

            let player80 = VideoMLPlayer.patched(
                VideoMLPlayer.play80Bytes,
                frameCount: f80.count, fps: fps, twoKBFrame: true
            )
            try await addFile(to: tempURL, name: "PLAY80.BIN",
                              data: player80, type: 0x06, aux: 0x0900)

            try await addFile(to: tempURL, name: "FRAMES80",
                              data: packFrames80(f80), type: 0x06, aux: 0x0000)
        }

        // 40-col LORES files (color blocks, /VIDEO/FRAMESLO)
        if let fLo = framesLores, !fLo.isEmpty {
            let playLo = ApplesoftTokenizer.tokenize(
                playWrapperSource(label: "40-COL LORES VIDEO",
                                  binName: "PLAYLO.BIN"))
            try await addFile(to: tempURL, name: "PLAYLO",
                              data: playLo, type: 0xFC, aux: 0x0801)

            let playerLo = VideoMLPlayer.patched(
                VideoMLPlayer.playLoresBytes,
                frameCount: fLo.count, fps: fps, twoKBFrame: false
            )
            try await addFile(to: tempURL, name: "PLAYLO.BIN",
                              data: playerLo, type: 0x06, aux: 0x0900)

            try await addFile(to: tempURL, name: "FRAMESLO",
                              data: packFramesLores(fLo), type: 0x06, aux: 0x0000)
        }

        // 80-col DLORES files (color blocks, /VIDEO/FRAMESDL)
        if let fDl = framesDlores, !fDl.isEmpty {
            let playDl = ApplesoftTokenizer.tokenize(
                playWrapperSource(label: "80-COL DLORES VIDEO",
                                  binName: "PLAYDL.BIN"))
            try await addFile(to: tempURL, name: "PLAYDL",
                              data: playDl, type: 0xFC, aux: 0x0801)

            let playerDl = VideoMLPlayer.patched(
                VideoMLPlayer.playDloresBytes,
                frameCount: fDl.count, fps: fps, twoKBFrame: true
            )
            try await addFile(to: tempURL, name: "PLAYDL.BIN",
                              data: playerDl, type: 0x06, aux: 0x0900)

            try await addFile(to: tempURL, name: "FRAMESDL",
                              data: packFramesDlores(fDl), type: 0x06, aux: 0x0000)
        }

        // Wrap in container format and write to the user's URL.
        let raw     = try Data(contentsOf: tempURL)
        let wrapped = DiskImageWriter.wrap(raw, format: format)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try wrapped.write(to: url, options: .atomic)
    }

    // MARK: - Boot block injection

    /// Copy blocks 0 and 1 (1024 bytes) from the template into the freshly
    /// built ProDOS volume at `url`. The template's blocks 0-1 are the real
    /// ProDOS boot loader — they search the volume directory for the file
    /// named "PRODOS" and load+execute it. Without this, the fresh volume
    /// has only ProDOSWriter's 128-byte boot stub and won't boot.
    private static func injectBootBlocks(from template: Data, to url: URL) throws {
        var data = try Data(contentsOf: url)
        let bootBytes = 1024
        guard template.count >= bootBytes, data.count >= bootBytes else {
            throw DiskExportError.write("Disk too small to inject boot blocks")
        }
        data.replaceSubrange(0..<bootBytes, with: template.prefix(bootBytes))
        try data.write(to: url, options: .atomic)
    }

    // MARK: - BASIC source

    private static func startupSource(has40: Bool, has80: Bool,
                                      hasLo: Bool, hasDl: Bool,
                                      count40: Int, count80: Int,
                                      countLo: Int, countDl: Int) -> String {
        // Collect the available modes in display order with their target
        // smart-RUN names.
        struct MenuEntry {
            let label: String   // e.g. "40-COL TEXT (5489 FRAMES)"
            let runArg: String  // e.g. "-PLAY40"
        }
        var entries: [MenuEntry] = []
        if has40 { entries.append(.init(label: "40-COL TEXT  (\(count40) FRAMES)",  runArg: "-PLAY40")) }
        if has80 { entries.append(.init(label: "80-COL TEXT  (\(count80) FRAMES)",  runArg: "-PLAY80")) }
        if hasLo { entries.append(.init(label: "40-COL LORES (\(countLo) FRAMES)",  runArg: "-PLAYLO")) }
        if hasDl { entries.append(.init(label: "80-COL DLORES(\(countDl) FRAMES)",  runArg: "-PLAYDL")) }

        // Single-mode disk: skip the menu and auto-launch the player.
        if entries.count == 1 {
            var src = ""
            src += "5 NOTRACE\r"
            src += "10 HOME\r"
            src += "20 PRINT CHR$(4);\"\(entries[0].runArg)\""
            return src
        }

        // Multi-mode disk — show the picker menu. Options are renumbered
        // sequentially so the labels match keys '1'..'N' regardless of
        // which combination is present.
        var src = ""
        src += "5 NOTRACE\r"
        src += "10 HOME\r"
        src += "20 PRINT \"            1977 VIDEO\"\r"
        src += "30 PRINT \"            ==========\"\r"
        src += "40 PRINT\r"

        var line = 50
        // SELECT prompt sits on row N+3 where N = number of menu rows
        // (title=1, ==== =2, blank=3, options=4..4+entries-1, blank, SELECT)
        for (idx, entry) in entries.enumerated() {
            src += "\(line) PRINT \"  \(idx + 1)) \(entry.label)\"\r"
            line += 10
        }
        src += "\(line) PRINT\r"; line += 10
        src += "\(line) PRINT \"  SELECT: \";\r"; line += 10
        let selectRow = 4 + entries.count + 1   // row where SELECT was printed

        // Credit pinned to row 23 of the 24-row screen.
        src += "\(line) VTAB 23\r"; line += 10
        src += "\(line) HTAB 1\r"; line += 10
        src += "\(line) PRINT \"  2026 WALTER TENGLER\"\r"; line += 10

        // Return cursor next to "  SELECT: " on the SELECT row.
        src += "\(line) VTAB \(selectRow)\r"; line += 10
        src += "\(line) HTAB 12\r"; line += 10
        src += "\(line) GET A$\r"; line += 10
        src += "\(line) PRINT A$\r"; line += 10
        for (idx, entry) in entries.enumerated() {
            src += "\(line) IF A$ = \"\(idx + 1)\" THEN PRINT CHR$(4);\"\(entry.runArg)\"\r"
            line += 10
        }
        src += "\(line) GOTO 10"
        return src
    }

    /// Builds a player wrapper: HOME → LOADING msg → BRUN player → (player
    /// runs animation, then RTS-es back) → reset display → re-launch STARTUP.
    ///
    /// **Why the wrapper has to be tiny.** Applesoft programs load at
    /// `$0801` and the player binary is `BRUN`-ed at `$0900` — only
    /// **255 bytes** of program space before the two regions collide. If
    /// the tokenized BASIC overflows past `$0900`, the `BRUN` overwrites
    /// the still-pending lines (you can see the damage by `LIST`-ing
    /// after playback: the lines past the overflow point decode as
    /// nonsense tokens — the player's machine code). Each BASIC line
    /// costs 5 bytes of overhead, so the wrapper still packs statements
    /// where it can.
    ///
    /// **BRUN must be on its own line.** When `PRINT CHR$(4);"BRUN ..."`
    /// fires, BASIC.SYSTEM intercepts the Ctrl-D, swallows the rest of
    /// the line as its command, and resumes Applesoft at the *next*
    /// program line. If `BRUN` is buried in the middle of a multi-
    /// statement line, the resume path corrupts Applesoft's text-pointer
    /// state and you get `?SYNTAX ERROR IN 10` after the player returns
    /// — even though the `LIST` of that line looks fine. Keeping `BRUN`
    /// as the only statement on its line sidesteps that.
    ///
    /// **Display reset after BRUN.** The player can leave the machine
    /// in 40-col text, 80-col text (PR#3 active), LORES, or DLORES.
    /// `TEXT` switches the display back to text — without it, a LORES
    /// player leaves graphics on and the STARTUP menu renders as color
    /// blocks. `POKE -16289,0` (STA `$C05F`) clears DHIRES (for DLORES).
    /// `PR# 0` unhooks the 80-col firmware before STARTUP runs.
    ///
    /// Player wrapper — `HOME` → `LOADING` msg → `BRUN` player → reset
    /// display → re-launch `STARTUP`. Single-mode disks loop the same
    /// video continuously (STARTUP auto-launches the only mode);
    /// multi-mode disks land back on the menu so the user can pick
    /// again. No interactive prompt — the user reboots (Ctrl-Reset) to
    /// quit, which is the standard Apple II "I'm done" gesture.
    ///
    /// **`NOTRACE` after the BRUN.** Something during slot-3 firmware
    /// init (`JSR $C300` inside the 80-col / DLORES players) leaves
    /// Applesoft's trace flag at `$F2` non-zero, so subsequent lines
    /// print as `#NN`. Explicit `NOTRACE` clears the flag before we
    /// re-launch STARTUP.
    ///
    /// **Why every statement is on its own line.** A `PRINT
    /// CHR$(4);"BRUN …"` mid-line corrupts Applesoft's text pointer on
    /// return; multi-statement lines after a Ctrl-D handoff also tend
    /// to trip the keyboard-hook quirks. Single-statement lines avoid
    /// all of that.
    private static func playWrapperSource(label: String,
                                          binName: String) -> String {
        _ = label   // intentionally unused — mode label dropped from msg
        var src = ""
        src += "10 HOME\r"
        src += "20 PRINT \"LOADING...\"\r"
        src += "30 PRINT CHR$(4);\"BRUN \(binName)\"\r"
        src += "40 NOTRACE\r"
        src += "45 TEXT\r"
        src += "50 POKE -16289,0\r"
        src += "60 PR# 0\r"
        src += "70 PRINT CHR$(4);\"-STARTUP\""
        return src
    }

    // MARK: - Helper

    private static func addFile(to disk: URL, name: String, data: Data,
                                type: UInt8, aux: UInt16) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ProDOSWriter.shared.addFile(
                diskImagePath: disk,
                fileName: name,
                fileData: data,
                fileType: type,
                auxType: aux
            ) { ok, msg in
                if ok { cont.resume() }
                else  { cont.resume(throwing: DiskExportError.write("\(name): \(msg)")) }
            }
        }
    }
}
