import Foundation

/// 6502 machine-language players that stream ASCII-art video frames from a
/// ProDOS sequential file into Apple II text page 1. Both players are loaded
/// at `$0900` via `BRUN`. `BRUN` jumps to the load address, so the first three
/// bytes MUST be a JMP — otherwise the CPU executes the patched frame count
/// as opcodes (which manifests as the disk hanging after the BASIC wrapper
/// prints the BRUN command). The byte layout is:
///
///     $0900: JMP $0906     (4C 06 09 — entry point)
///     $0903: FRAME_LO      (total frame count, low byte)   [patched]
///     $0904: FRAME_HI      (total frame count, high byte)  [patched]
///     $0905: FPS_DLY       (outer delay-loop iterations)   [patched]
///     $0906: INIT          (the real code)
///
/// The 40-col player opens `FRAMES40`, reads 1 KB chunks into `$2000`, then
/// linearly copies them to text page 1 at `$0400-$07FF`. The 80-col player
/// opens `FRAMES80`, reads 2 KB chunks into `$4000`, splits them between
/// AUX `$0400` (via PAGE2 ON) and MAIN `$0400` (PAGE2 OFF). Both use ProDOS
/// MLI calls (`$BF00`) for file I/O.
///
/// Linear copies to `$0400` are correct because
/// `AppleIIScreenMemory.buildScreen40/80()` pre-scrambles each frame into the
/// non-contiguous text-page layout — the same trick `LOADER40/80` already use.
enum VideoMLPlayer {

    // MARK: - 40-column player
    //
    // Core: 162 bytes ($0900-$09A1); `withDelay` appends DELAY at $09A2.
    // Code path:
    //   • INIT — copy FRAME counter to REMAIN; MLI OPEN FRAMES40; HOME.
    //   • LOOP — if REMAIN==0, jump to DONE. MLI READ 1024 → $2000.
    //            Unrolled 4-page copy to $0400. Delay loop. Decrement
    //            REMAIN. Repeat.
    //   • DONE — MLI CLOSE, RTS to BASIC.
    private static let play40Base: [UInt8] = withDelay(play40Core, ldyOffset: 0x53)

    /// 40-col player plus CLEAR and FINISH (see `withClearAndFinish`).
    /// `clear` is CLEAR's address, reused by the LORES variant.
    private static let play40Pre = withClearAndFinish(
        play40Base, doneJSR: 0x6C, cparms: 0x0990, quit: 0x0972, is80: false)

    static let play40Bytes: [UInt8] = play40Pre.bytes

    private static let play40Core: [UInt8] = [
        // --- Header: JMP to ENTRY_STUB, then the patchable data bytes ---
        // BRUN lands at $0900, so $0900-$0902 must be executable.
        // Entry goes via a diagnostic stub at $0977 (in the padding
        // area) that writes 'A' to $0400 and then falls into the
        // real INIT at $0906 — gives us proof-of-life on screen.
        0x4C, 0x77, 0x09,       // $0900 JMP $0977   (ENTRY_STUB)
        0x00,                   // $0903 FRAME_LO   [patched at file offset 3]
        0x00,                   // $0904 FRAME_HI   [patched at file offset 4]
        0x00,                   // $0905 FPS_DLY    [patched at file offset 5]

        // --- INIT at $0906: REMAIN ← FRAME ---
        0xAD, 0x03, 0x09,       // $0906 LDA $0903    (FRAME_LO)
        0x8D, 0x80, 0x09,       // $0909 STA $0980    (REMAIN_LO)
        0xAD, 0x04, 0x09,       // $090C LDA $0904    (FRAME_HI)
        0x8D, 0x81, 0x09,       // $090F STA $0981    (REMAIN_HI)

        // --- MLI OPEN ---
        0x20, 0x00, 0xBF,       // $0912 JSR $BF00
        0xC8,                   // $0915 .BYTE $C8    (OPEN)
        0x82, 0x09,             // $0916 .WORD $0982  (OPARMS)
        0xD0, 0x59,             // $0918 BNE +89 → $0973 (ERROR_STUB)

        // --- Copy file_ref_num into RPARMS+1 and CPARMS+1 ---
        0xAD, 0x87, 0x09,       // $091A LDA $0987    (OPARMS+5 = ref_num)
        0x8D, 0x89, 0x09,       // $091D STA $0989    (RPARMS+1)
        0x8D, 0x91, 0x09,       // $0920 STA $0991    (CPARMS+1)

        // --- HOME ($FC58 clears the 40-col text screen) ---
        0x20, 0x58, 0xFC,       // $0923 JSR $FC58

        // --- LOOP at $0926: check REMAIN ---
        0xAD, 0x80, 0x09,       // $0926 LDA $0980    (REMAIN_LO)
        0x0D, 0x81, 0x09,       // $0929 ORA $0981    (REMAIN_HI)
        0xF0, 0x3E,             // $092C BEQ +62 → $096C (DONE)

        // --- MLI READ 1024 bytes → $2000 ---
        0x20, 0x00, 0xBF,       // $092E JSR $BF00
        0xCA,                   // $0931 .BYTE $CA    (READ)
        0x88, 0x09,             // $0932 .WORD $0988  (RPARMS)
        0xD0, 0x36,             // $0934 BNE +54 → $096C (DONE on EOF/err)

        // --- Copy $2000-$23FF → $0400-$07FF (unrolled, 4 pages) ---
        0xA2, 0x00,             // $0936 LDX #$00
        // COPY at $0938:
        0xBD, 0x00, 0x20,       // $0938 LDA $2000,X
        0x9D, 0x00, 0x04,       // $093B STA $0400,X
        0xBD, 0x00, 0x21,       // $093E LDA $2100,X
        0x9D, 0x00, 0x05,       // $0941 STA $0500,X
        0xBD, 0x00, 0x22,       // $0944 LDA $2200,X
        0x9D, 0x00, 0x06,       // $0947 STA $0600,X
        0xBD, 0x00, 0x23,       // $094A LDA $2300,X
        0x9D, 0x00, 0x07,       // $094D STA $0700,X
        0xE8,                   // $0950 INX
        0xD0, 0xE5,             // $0951 BNE -27 → $0938 (COPY)

        // --- Delay (FPS pacing) ---
        // `withDelay` replaces this LDY with JSR DELAY, which runs the
        // long delay and returns Y=1 so the loop below runs once.
        0xAC, 0x05, 0x09,       // $0953 LDY $0905    (FPS_DLY)
        // DOUT at $0956:
        0xA2, 0x00,             // $0956 LDX #$00
        // DIN at $0958:
        0xCA,                   // $0958 DEX
        0xD0, 0xFD,             // $0959 BNE -3 → $0958
        0x88,                   // $095B DEY
        0xD0, 0xF8,             // $095C BNE -8 → $0956

        // --- Decrement REMAIN (16-bit) ---
        0xAD, 0x80, 0x09,       // $095E LDA $0980    (REMAIN_LO)
        0xD0, 0x03,             // $0961 BNE +3 → $0966 (SKIP_HI)
        0xCE, 0x81, 0x09,       // $0963 DEC $0981    (REMAIN_HI)
        // SKIP_HI at $0966:
        0xCE, 0x80, 0x09,       // $0966 DEC $0980    (REMAIN_LO)
        0x4C, 0x26, 0x09,       // $0969 JMP $0926    (LOOP)

        // --- DONE at $096C: MLI CLOSE, RTS ---
        0x20, 0x00, 0xBF,       // $096C JSR $BF00
        0xCC,                   // $096F .BYTE $CC    (CLOSE)
        0x90, 0x09,             // $0970 .WORD $0990  (CPARMS)
        // QUIT at $0972:
        0x60,                   // $0972 RTS

        // --- ERROR_STUB at $0973 (jumped to from BNE QUIT) ---
        // A holds the MLI error code (e.g. $46 = file not found).
        // Write it verbatim to the top-left of the screen so the user
        // sees a flashing letter on failure instead of a blank prompt.
        0x8D, 0x00, 0x04,       // $0973 STA $0400   (display error code)
        0x60,                   // $0976 RTS
        // --- ENTRY_STUB at $0977 (jumped to from JMP at $0900) ---
        // Write a normal-video 'A' at $0400 as proof the player ran,
        // then fall into the real INIT at $0906.
        0xA9, 0xC1,             // $0977 LDA #$C1    ('A', high-bit-set = normal video)
        0x8D, 0x00, 0x04,       // $0979 STA $0400   (top-left of text page 1)
        0x4C, 0x06, 0x09,       // $097C JMP $0906   (real INIT)
        0x00,                   // $097F padding

        // --- Data at $0980 ---
        0x00,                   // $0980 REMAIN_LO
        0x00,                   // $0981 REMAIN_HI

        // OPARMS at $0982 (6 bytes):
        0x03,                   // $0982 param_count = 3
        0x92, 0x09,             // $0983 pathname    = $0992 (FNAME)
        0x00, 0x70,             // $0985 io_buffer   = $7000  (avoid $1000 — BASIC.SYSTEM may have buffers there, MLI returns $50/"file busy")
        0x00,                   // $0987 ref_num     (output)

        // RPARMS at $0988 (8 bytes):
        0x04,                   // $0988 param_count = 4
        0x00,                   // $0989 ref_num     (patched at runtime)
        0x00, 0x20,             // $098A data_buffer = $2000
        0x00, 0x04,             // $098C request_cnt = 1024 ($0400)
        0x00, 0x00,             // $098E trans_cnt   (output)

        // CPARMS at $0990 (2 bytes):
        0x01,                   // $0990 param_count = 1
        0x00,                   // $0991 ref_num     (patched at runtime)

        // FNAME at $0992 — **absolute** path "/VIDEO/FRAMES40".
        //
        // Relative paths like just "FRAMES40" resolve against ProDOS's
        // current prefix, which isn't always set when a BIN file is
        // BRUNned from BASIC.SYSTEM on an HDV — MLI then returns $40
        // (invalid pathname syntax). Absolute paths bypass the prefix.
        0x0F,                                                       // $0992 length = 15
        0x2F, 0x56, 0x49, 0x44, 0x45, 0x4F, 0x2F,                   // "/VIDEO/"
        0x46, 0x52, 0x41, 0x4D, 0x45, 0x53, 0x34, 0x30,             // "FRAMES40"
    ]

    // MARK: - 80-column player
    //
    // Core: 194 bytes ($0900-$09C1); `withDelay` appends DELAY at $09C2.
    // Differences from the 40-col player:
    //   • Reads 2048 bytes into $4000 (HIRES page 2 — RAMWRT-switched, not
    //     80STORE-switched, so PAGE2 won't redirect $4000 reads to AUX).
    //   • Splits the chunk: first 1024 → AUX $0400 (PAGE2 ON), second 1024
    //     → MAIN $0400 (PAGE2 OFF).
    //   • Switches to 80-col internally via `JSR $C300` (the slot-3
    //     firmware entry — same code path `PR# 3` invokes).  Doing this
    //     from inside the player lets the BASIC wrapper BRUN us while
    //     still in 40-col mode, avoiding the well-known BASIC.SYSTEM
    //     ordering bug where `PR# 3` before a Ctrl-D command leaves
    //     COUT redirected to the 80-col card and the BRUN never reaches
    //     BASIC.SYSTEM.
    //   • FNAME = "FRAMES80".
    private static let play80Base: [UInt8] = withDelay(play80Core, ldyOffset: 0x76)

    /// 80-col player plus CLEAR and FINISH; the text and DLORES variants
    /// each append their own display-setup routine after it.
    private static let play80Pre = withClearAndFinish(
        play80Base, doneJSR: 0x8F, cparms: 0x09B0, quit: 0x0995, is80: true)

    /// Fills the *visible* text-page bytes of `$0400-$07FF` with A, skipping
    /// the eight "screen hole" bytes at `+$78…+$7F` of every 128-byte
    /// block. The holes aren't displayed but belong to the firmware: the
    /// 80-col card keeps its cursor, mode flags and active-slot number
    /// there (`$057B`, `$05FB`, `$07F8`, …). Filling them with `$A0` left
    /// the menu printing at the wrong place after a DLORES run.
    ///
    ///     CLEAR: LDX #$77
    ///     C1:    STA $0400,X / $0500,X / $0600,X / $0700,X
    ///            DEX
    ///            BPL C1              ; offsets $77…$00
    ///            LDX #$F7
    ///     C2:    STA $0400,X / … / $0700,X
    ///            DEX
    ///            CPX #$7F
    ///            BNE C2              ; offsets $F7…$80
    ///            RTS
    ///
    /// Used at both ends of playback. The display is switched before the
    /// first frame has been read from disk (~125-250 ms), so without a
    /// clear whatever the screen memory held — the wrapper's LOADING text
    /// or the previous run's last frame, still sitting in the AUX bank —
    /// shows until then. And when the player returns, the wrapper's
    /// `TEXT` / 80COL-off would expose the last LORES / 80-col frame as
    /// garbled characters until STARTUP's `HOME`.
    private static let clearRoutine: [UInt8] = [
        0xA2, 0x77,             // +0  LDX #$77
        0x9D, 0x00, 0x04,       // +2  C1: STA $0400,X
        0x9D, 0x00, 0x05,       // +5  STA $0500,X
        0x9D, 0x00, 0x06,       // +8  STA $0600,X
        0x9D, 0x00, 0x07,       // +11 STA $0700,X
        0xCA,                   // +14 DEX
        0x10, 0xF1,             // +15 BPL C1
        0xA2, 0xF7,             // +17 LDX #$F7
        0x9D, 0x00, 0x04,       // +19 C2: STA $0400,X
        0x9D, 0x00, 0x05,       // +22 STA $0500,X
        0x9D, 0x00, 0x06,       // +25 STA $0600,X
        0x9D, 0x00, 0x07,       // +28 STA $0700,X
        0xCA,                   // +31 DEX
        0xE0, 0x7F,             // +32 CPX #$7F
        0xD0, 0xEF,             // +34 BNE C2
        0x60,                   // +36 RTS
    ]

    /// Appends CLEAR and FINISH to `base`, and points the core's DONE
    /// `JSR $BF00` (MLI CLOSE, at file offset `doneJSR`) at FINISH.
    ///
    ///     FINISH: JSR $BF00 / CLOSE / CPARMS   ; same close as DONE
    ///             STA $C051                    ; text mode
    ///             LDA #$A0                     ; space
    ///             JSR CLEAR                    ; (80-col: PAGE2 on → AUX,
    ///                                          ;  CLEAR, PAGE2 off → MAIN,
    ///                                          ;  CLEAR)
    ///             PLA / PLA                    ; drop FINISH's return address
    ///             JMP QUIT                     ; the core's RTS back to BASIC
    private static func withClearAndFinish(
        _ base: [UInt8], doneJSR: Int, cparms: Int, quit: Int, is80: Bool
    ) -> (bytes: [UInt8], clear: Int) {
        precondition(Array(base[doneJSR..<doneJSR + 3]) == [0x20, 0x00, 0xBF],
                     "player core changed — DONE's JSR $BF00 not at expected offset")
        var b = base
        let clear = loadAddress + b.count
        b.append(contentsOf: clearRoutine)
        let finish = loadAddress + b.count
        b[doneJSR + 1] = UInt8(finish & 0xFF)
        b[doneJSR + 2] = UInt8(finish >> 8)
        let jsrClear: [UInt8] = [0x20, UInt8(clear & 0xFF), UInt8(clear >> 8)]
        var f: [UInt8] = [
            0x20, 0x00, 0xBF,                              // JSR $BF00
            0xCC, UInt8(cparms & 0xFF), UInt8(cparms >> 8), // CLOSE, CPARMS
            0x8D, 0x51, 0xC0,                              // STA $C051 (TEXT on)
            0xA9, 0xA0,                                    // LDA #$A0
        ]
        if is80 {
            f += [0x8D, 0x55, 0xC0] + jsrClear             // PAGE2 on → AUX
            f += [0x8D, 0x54, 0xC0] + jsrClear             // PAGE2 off → MAIN
        } else {
            f += jsrClear
        }
        f += [0x68, 0x68, 0x4C, UInt8(quit & 0xFF), UInt8(quit >> 8)]
        b.append(contentsOf: f)
        return (b, clear)
    }

    /// 80-col TEXT player. `JSR $C300` at `$0923` is replaced by
    /// `JSR SET80`:
    ///
    ///     SET80: JSR $C300   ; 80-col card init (80STORE on)
    ///            LDA #$A0    ; space
    ///            STA $C055   ; PAGE2 on  → $0400 writes go to AUX
    ///            JSR CLEAR
    ///            STA $C054   ; PAGE2 off → MAIN
    ///            JSR CLEAR
    ///            RTS
    static let play80Bytes: [UInt8] = {
        var b = play80Pre.bytes
        let clear = play80Pre.clear
        let set80 = loadAddress + b.count
        b[0x24] = UInt8(set80 & 0xFF)
        b[0x25] = UInt8(set80 >> 8)
        b.append(contentsOf: [
            0x20, 0x00, 0xC3,                                // JSR $C300
            0xA9, 0xA0,                                      // LDA #$A0
            0x8D, 0x55, 0xC0,                                // STA $C055
            0x20, UInt8(clear & 0xFF), UInt8(clear >> 8),    // JSR CLEAR
            0x8D, 0x54, 0xC0,                                // STA $C054
            0x20, UInt8(clear & 0xFF), UInt8(clear >> 8),    // JSR CLEAR
            0x60,                                            // RTS
        ])
        return b
    }()

    private static let play80Core: [UInt8] = [
        // --- Header: JMP to ENTRY_STUB, then the patchable data bytes ---
        // Entry goes via a diagnostic stub at $099A (in the padding
        // area between code and data) that beeps and falls into the
        // real INIT — gives us audible proof-of-life.
        0x4C, 0x9A, 0x09,       // $0900 JMP $099A   (ENTRY_STUB)
        0x00,                   // $0903 FRAME_LO   [patched at file offset 3]
        0x00,                   // $0904 FRAME_HI   [patched at file offset 4]
        0x00,                   // $0905 FPS_DLY    [patched at file offset 5]

        // --- INIT at $0906 ---
        0xAD, 0x03, 0x09,       // $0906 LDA $0903    (FRAME_LO)
        0x8D, 0xA0, 0x09,       // $0909 STA $09A0    (REMAIN_LO)
        0xAD, 0x04, 0x09,       // $090C LDA $0904    (FRAME_HI)
        0x8D, 0xA1, 0x09,       // $090F STA $09A1    (REMAIN_HI)

        // --- MLI OPEN (still in 40-col mode, BASIC.SYSTEM hooked) ---
        0x20, 0x00, 0xBF,       // $0912 JSR $BF00
        0xC8,                   // $0915 .BYTE $C8    (OPEN)
        0xA2, 0x09,             // $0916 .WORD $09A2  (OPARMS)
        0xD0, 0x7C,             // $0918 BNE +124 → $0996 (ERROR_STUB)

        // --- Copy file_ref_num ---
        0xAD, 0xA7, 0x09,       // $091A LDA $09A7    (OPARMS+5)
        0x8D, 0xA9, 0x09,       // $091D STA $09A9    (RPARMS+1)
        0x8D, 0xB1, 0x09,       // $0920 STA $09B1    (CPARMS+1)

        // --- Activate 80-col mode (equivalent to `PR# 3`) ---
        0x20, 0x00, 0xC3,       // $0923 JSR $C300

        // --- LOOP at $0926 ---
        0xAD, 0xA0, 0x09,       // $0926 LDA $09A0    (REMAIN_LO)
        0x0D, 0xA1, 0x09,       // $0929 ORA $09A1    (REMAIN_HI)
        0xF0, 0x61,             // $092C BEQ +97 → $098F (DONE)

        // --- MLI READ 2048 bytes → $4000 ---
        0x20, 0x00, 0xBF,       // $092E JSR $BF00
        0xCA,                   // $0931 .BYTE $CA    (READ)
        0xA8, 0x09,             // $0932 .WORD $09A8  (RPARMS)
        0xD0, 0x59,             // $0934 BNE +89 → $098F (DONE)

        // --- PAGE2 ON: $0400 writes redirect to AUX (80STORE is on) ---
        0x8D, 0x55, 0xC0,       // $0936 STA $C055

        // --- Copy $4000-$43FF → $0400 (lands in AUX bank) ---
        0xA2, 0x00,             // $0939 LDX #$00
        // COPY_AUX at $093B:
        0xBD, 0x00, 0x40,       // $093B LDA $4000,X
        0x9D, 0x00, 0x04,       // $093E STA $0400,X
        0xBD, 0x00, 0x41,       // $0941 LDA $4100,X
        0x9D, 0x00, 0x05,       // $0944 STA $0500,X
        0xBD, 0x00, 0x42,       // $0947 LDA $4200,X
        0x9D, 0x00, 0x06,       // $094A STA $0600,X
        0xBD, 0x00, 0x43,       // $094D LDA $4300,X
        0x9D, 0x00, 0x07,       // $0950 STA $0700,X
        0xE8,                   // $0953 INX
        0xD0, 0xE5,             // $0954 BNE -27 → $093B (COPY_AUX)

        // --- PAGE2 OFF: back to MAIN ---
        0x8D, 0x54, 0xC0,       // $0956 STA $C054

        // --- Copy $4400-$47FF → $0400 (lands in MAIN bank) ---
        0xA2, 0x00,             // $0959 LDX #$00
        // COPY_MAIN at $095B:
        0xBD, 0x00, 0x44,       // $095B LDA $4400,X
        0x9D, 0x00, 0x04,       // $095E STA $0400,X
        0xBD, 0x00, 0x45,       // $0961 LDA $4500,X
        0x9D, 0x00, 0x05,       // $0964 STA $0500,X
        0xBD, 0x00, 0x46,       // $0967 LDA $4600,X
        0x9D, 0x00, 0x06,       // $096A STA $0600,X
        0xBD, 0x00, 0x47,       // $096D LDA $4700,X
        0x9D, 0x00, 0x07,       // $0970 STA $0700,X
        0xE8,                   // $0973 INX
        0xD0, 0xE5,             // $0974 BNE -27 → $095B (COPY_MAIN)

        // --- Delay (replaced by JSR DELAY, see `withDelay`) ---
        0xAC, 0x05, 0x09,       // $0976 LDY $0905    (FPS_DLY)
        // DOUT at $0979:
        0xA2, 0x00,             // $0979 LDX #$00
        // DIN at $097B:
        0xCA,                   // $097B DEX
        0xD0, 0xFD,             // $097C BNE -3
        0x88,                   // $097E DEY
        0xD0, 0xF8,             // $097F BNE -8

        // --- Decrement REMAIN ---
        0xAD, 0xA0, 0x09,       // $0981 LDA $09A0
        0xD0, 0x03,             // $0984 BNE +3 → $0989 (SKIP_HI)
        0xCE, 0xA1, 0x09,       // $0986 DEC $09A1
        // SKIP_HI at $0989:
        0xCE, 0xA0, 0x09,       // $0989 DEC $09A0
        0x4C, 0x26, 0x09,       // $098C JMP $0926    (LOOP)

        // --- DONE at $098F ---
        0x20, 0x00, 0xBF,       // $098F JSR $BF00
        0xCC,                   // $0992 .BYTE $CC    (CLOSE)
        0xB0, 0x09,             // $0993 .WORD $09B0  (CPARMS)
        // QUIT at $0995:
        0x60,                   // $0995 RTS

        // --- ERROR_STUB at $0996 (jumped to from BNE QUIT) ---
        // A holds the MLI error code; write it to $0400 so the user
        // sees a flashing letter at top-left on failure. We're still
        // in 40-col mode (OPEN fails before JSR $C300), so $0400 is
        // the standard 40-col text page visible to the user.
        0x8D, 0x00, 0x04,       // $0996 STA $0400   (display error code)
        0x60,                   // $0999 RTS
        // --- ENTRY_STUB at $099A (jumped to from JMP at $0900) ---
        // Beep audibly to prove the player ran, then fall into INIT.
        0x20, 0xDD, 0xFB,       // $099A JSR $FBDD   (BELL1 — beep)
        0x4C, 0x06, 0x09,       // $099D JMP $0906   (real INIT)

        // --- Data at $09A0 ---
        0x00,                   // $09A0 REMAIN_LO
        0x00,                   // $09A1 REMAIN_HI

        // OPARMS at $09A2 (6 bytes):
        0x03,                   // $09A2 param_count = 3
        0xB2, 0x09,             // $09A3 pathname    = $09B2 (FNAME)
        0x00, 0x70,             // $09A5 io_buffer   = $7000  (avoid $1000 — BASIC.SYSTEM may have buffers there)
        0x00,                   // $09A7 ref_num

        // RPARMS at $09A8 (8 bytes):
        0x04,                   // $09A8 param_count = 4
        0x00,                   // $09A9 ref_num
        0x00, 0x40,             // $09AA data_buffer = $4000
        0x00, 0x08,             // $09AC request_cnt = 2048 ($0800)
        0x00, 0x00,             // $09AE trans_cnt

        // CPARMS at $09B0 (2 bytes):
        0x01,                   // $09B0 param_count = 1
        0x00,                   // $09B1 ref_num

        // FNAME at $09B2 — **absolute** path "/VIDEO/FRAMES80".
        // Same rationale as 40-col player above.
        0x0F,                                                       // $09B2 length = 15
        0x2F, 0x56, 0x49, 0x44, 0x45, 0x4F, 0x2F,                   // "/VIDEO/"
        0x46, 0x52, 0x41, 0x4D, 0x45, 0x53, 0x38, 0x30,             // "FRAMES80"
    ]

    // MARK: - LORES (40 cols × 48 vert color blocks)
    //
    // Identical to `play40Bytes` except:
    //   • The post-OPEN `JSR $FC58` (HOME) at `$0923` is swapped for
    //     `JSR SETLORES` — a tiny subroutine appended after DELAY
    //     ($09B7).
    //   • FNAME tail changes from "FRAMES40" to "FRAMESLO" so the
    //     player opens `/VIDEO/FRAMESLO` instead of the text frames.
    //
    // SETLORES:
    //     STA $C050  ; TEXT off / GR on
    //     STA $C052  ; MIXED off (full graphics)
    //     STA $C056  ; HIRES off → LORES
    //     STA $C054  ; PAGE2 off (TXTPAGE1 — main $0400)
    //     LDA #0     ; black
    //     JSR CLEAR  ; otherwise the leftover text page shows as grey
    //                ; stripes until the first frame arrives
    //     RTS
    static let playLoresBytes: [UInt8] = {
        var b = play40Pre.bytes
        let clear = play40Pre.clear
        // JSR $FC58 (HOME) at $0923 → JSR SETLORES (appended below)
        let setLores = loadAddress + b.count
        b[0x24] = UInt8(setLores & 0xFF)
        b[0x25] = UInt8(setLores >> 8)
        // FNAME tail "40" → "LO" (offsets $A0, $A1 = file bytes 0xA0, 0xA1)
        b[0xA0] = 0x4C   // 'L'
        b[0xA1] = 0x4F   // 'O'
        // Append SETLORES
        b.append(contentsOf: [
            0x8D, 0x50, 0xC0,    // STA $C050
            0x8D, 0x52, 0xC0,    // STA $C052
            0x8D, 0x56, 0xC0,    // STA $C056
            0x8D, 0x54, 0xC0,    // STA $C054
            0xA9, 0x00,          // LDA #$00
            0x20, UInt8(clear & 0xFF), UInt8(clear >> 8),   // JSR CLEAR
            0x60,                // RTS
        ])
        return b
    }()

    // MARK: - Double-LORES (80 cols × 48 vert color blocks)
    //
    // Identical to the 80-col text player except:
    //   • The `JSR $C300` (slot-3 80-col-card init) at `$0923` is
    //     swapped for `JSR SETDLORES` — a subroutine appended after
    //     DELAY ($09D7).
    //   • FNAME tail changes from "FRAMES80" to "FRAMESDL".
    //
    // SETDLORES:
    //     JSR $C300  ; slot-3 init: turns on 80STORE + 80COL + ALTCHAR
    //                ;             (puts us briefly in 80-col TEXT)
    //     STA $C050  ; TEXT off → GR
    //     STA $C052  ; MIXED off → FULL
    //     STA $C056  ; HIRES off → LORES
    //     STA $C05E  ; DHIRES on → DLORES
    //     LDA #0     ; black
    //     STA $C055 / JSR CLEAR   ; clear AUX
    //     STA $C054 / JSR CLEAR   ; clear MAIN (no stale last frame in
    //                             ; either bank while the first loads)
    //     RTS
    //
    // Why JSR $C300 and not bare STA $C001: pure `80STORE` ON without
    // `80COL` ON makes the LORES decoder fetch only MAIN bank and ignore
    // AUX, which renders the 80-col DLORES output as a 40-col strip.
    // $C300 sets all three display-side bits (80STORE + 80COL + ALTCHAR)
    // in one shot — same call the working 80-col TEXT player uses.
    //
    // The AUX/MAIN copy loop in `play80Core` is reused verbatim — same
    // PAGE2 toggle, same `$4000` staging buffer, same READ size.
    static let playDloresBytes: [UInt8] = {
        var b = play80Pre.bytes
        let clear = play80Pre.clear
        // JSR $C300 at $0923 → JSR SETDLORES (appended below)
        let setDlores = loadAddress + b.count
        b[0x24] = UInt8(setDlores & 0xFF)
        b[0x25] = UInt8(setDlores >> 8)
        // FNAME tail "80" → "DL" (offsets 0xC0, 0xC1)
        b[0xC0] = 0x44   // 'D'
        b[0xC1] = 0x4C   // 'L'
        // Append SETDLORES
        b.append(contentsOf: [
            0x20, 0x00, 0xC3,    // JSR $C300 (80-col card init)
            0x8D, 0x50, 0xC0,    // STA $C050 (TEXT off / GR on)
            0x8D, 0x52, 0xC0,    // STA $C052 (MIXED off / FULL)
            0x8D, 0x56, 0xC0,    // STA $C056 (HIRES off / LORES)
            0x8D, 0x5E, 0xC0,    // STA $C05E (DHIRES on → DLORES)
            0xA9, 0x00,          // LDA #$00
            0x8D, 0x55, 0xC0,    // STA $C055 (PAGE2 on → AUX)
            0x20, UInt8(clear & 0xFF), UInt8(clear >> 8),   // JSR CLEAR
            0x8D, 0x54, 0xC0,    // STA $C054 (PAGE2 off → MAIN)
            0x20, UInt8(clear & 0xFF), UInt8(clear >> 8),   // JSR CLEAR
            0x60,                // RTS
        ])
        return b
    }()

    // MARK: - FPS delay

    /// `BRUN` address of every player.
    private static let loadAddress = 0x0900

    /// DELAY subroutine, called in place of the core's `LDY FPS_DLY`.
    /// Each outer iteration runs four 256-count DEX loops (5158 cycles,
    /// ≈ 5.04 ms at 1.023 MHz), so FPS_DLY = 255 covers ≈ 1.29 s — enough
    /// for 1 fps. The original 1.25 ms-per-unit loop topped out at 320 ms,
    /// which made 1 and 2 fps play at ≈ 2.2 fps.
    ///
    ///     DELAY: LDY $0905   ; FPS_DLY
    ///     D1:    LDA #4
    ///     D2:    LDX #0
    ///     D3:    DEX
    ///            BNE D3
    ///            SEC
    ///            SBC #1
    ///            BNE D2
    ///            DEY
    ///            BNE D1
    ///            LDY #1      ; core's own delay loop then runs once
    ///            RTS
    private static let delayRoutine: [UInt8] = [
        0xAC, 0x05, 0x09,       // +0  LDY $0905
        0xA9, 0x04,             // +3  D1: LDA #4
        0xA2, 0x00,             // +5  D2: LDX #0
        0xCA,                   // +7  D3: DEX
        0xD0, 0xFD,             // +8  BNE D3
        0x38,                   // +10 SEC
        0xE9, 0x01,             // +11 SBC #1
        0xD0, 0xF6,             // +13 BNE D2
        0x88,                   // +15 DEY
        0xD0, 0xF1,             // +16 BNE D1
        0xA0, 0x01,             // +18 LDY #1
        0x60,                   // +20 RTS
    ]

    /// Append DELAY to `core` and turn its `LDY $0905` at `ldyOffset`
    /// into `JSR DELAY` (both are 3 bytes, so nothing else moves).
    private static func withDelay(_ core: [UInt8], ldyOffset: Int) -> [UInt8] {
        precondition(Array(core[ldyOffset..<ldyOffset + 3]) == [0xAC, 0x05, 0x09],
                     "player core changed — LDY FPS_DLY not at expected offset")
        var b = core
        let delay = loadAddress + core.count
        b[ldyOffset]     = 0x20                       // JSR
        b[ldyOffset + 1] = UInt8(delay & 0xFF)
        b[ldyOffset + 2] = UInt8(delay >> 8)
        b.append(contentsOf: delayRoutine)
        return b
    }

    /// Picks FPS_DLY so each frame is padded up to the target period.
    /// Assumes the ~125 ms disk read for a 40-col frame (~250 ms for
    /// 80-col); each DELAY unit is ≈ 5.04 ms, plus a fixed ≈ 1.26 ms for
    /// the single pass of the core's own loop. Clamped to 1…255; the
    /// byte lives at file offset 5 of the player.
    static func fpsDelayValue(fps: Double, twoKBFrame: Bool = false) -> UInt8 {
        guard fps > 0 else { return 1 }
        let periodMs  = 1000.0 / fps
        let readMs    = twoKBFrame ? 250.0 : 125.0    // ProDOS ≈ 8 KB/s
        let budgetMs  = max(0, periodMs - readMs - 1.26)
        let unitMs    = 5.04
        let count     = max(1, Int((budgetMs / unitMs).rounded()))
        return UInt8(min(count, 255))
    }

    /// Patch the three data bytes that follow the entry JMP with the
    /// actual frame count and FPS delay. Bytes 0-2 of the binary are the
    /// JMP itself and must never change; the patchable header is at
    /// file offsets 3 (FRAME_LO), 4 (FRAME_HI), 5 (FPS_DLY).
    static func patched(_ bytes: [UInt8], frameCount: Int, fps: Double, twoKBFrame: Bool) -> Data {
        var out = bytes
        out[3] = UInt8(frameCount & 0xFF)
        out[4] = UInt8((frameCount >> 8) & 0xFF)
        out[5] = fpsDelayValue(fps: fps, twoKBFrame: twoKBFrame)
        return Data(out)
    }
}
