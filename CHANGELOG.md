# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Movie → Apple II video converter** (Video window): converts MP4/MOV into a bootable ProDOS disk with a 6502 ML player. Output modes: 40-col text, 80-col text, 40-col LORES color, 80-col Double-LORES color — any combination on one disk, with a STARTUP menu
- Disk formats: 140 KB and 800 KB floppy (`.po`), 32 MB hard disk (`.2mg`, `.hdv`)
- Exact per-disk frame capacity, computed from the real PRODOS / BASIC.SYSTEM sizes and generated programs (see Fixed)

### Changed
- Video playback delay is now accurate down to 1 fps (was limited to about 320 ms per frame, so 1 and 2 fps both played at about 2.2 fps)
- Non-ASCII characters (e.g. from block-element ramps) are written as spaces in Apple II text, Applesoft BASIC and disk exports, so rows keep their width
- Video window: opening a movie, re-extracting and exporting are disabled while a job is running; settings changed during extraction are applied once extraction finishes

### Fixed
- **Disk capacity overestimate** — exporting at the advertised maximum frame count failed with "Not enough free blocks" (for example 99 or more 40-col frames on a 140 KB disk). The block allocator also skipped blocks 0–23 even when free
- **Corrupt 256-block files** — a file with exactly 256 data blocks was marked as a tree file but laid out as a sapling and read back as empty (hit at 128 frames of 40-col, 64 of 80-col)
- **Files over 16 MB** are now rejected with an error instead of being silently truncated; the frame limit on 32 MB disks accounts for this
- **Slow 32 MB exports** — block allocation copied the whole disk image per block (a 4 MB file took about 20 s, 17 MB about 84 s); it now edits in place and takes well under a second
- LORES / DLORES disks returned to the STARTUP menu in graphics mode, so the menu showed as color blocks; the player wrapper now switches back to text
- Screen artifacts when video disks switched modes: LORES showed the leftover text page as grey stripes before the first frame, 80-col / DLORES showed stale AUX-bank contents, and the last LORES / 80-col frame appeared as garbled characters when playback ended. The players now clear the visible text page (both banks for 80-col, sparing the firmware's screen-hole bytes) when starting and finishing
- Exported video disks stopped after the first playback instead of restarting or returning to the menu. The wrapper's `PR# 0` dropped BASIC.SYSTEM's I/O hooks, so `-STARTUP` was printed as text; and after 80-col / DLORES playback the 80-column text window made STARTUP's `HOME` overwrite the loaded program (`?SYNTAX ERROR IN 10`). The wrapper now saves and restores the hooks and resets the window to 40 columns. Verified by booting exported disks in MAME (Apple IIe and IIgs)
- Image disk export ignored the crop selection
- Applesoft BASIC export failed (and disk export misaligned rows) when the ramp contained non-ASCII characters, such as Apple II Blocks
- ProDOS creation timestamps had the minute and hour swapped and a year of 126 instead of 26
- The Applesoft tokenizer never tokenized `&`
- Starting a second video load or export while one was running could overwrite frame buffers or write a partial disk
- LORES palette comments labelled the two grays the wrong way round (no change to colors); removed `[v4]` debug tags from video status messages

## [1.1.0] - 2026-05-07

### Added
- **9 new platforms** alongside Apple II 40/80-col: Commodore PET, Commodore 64, Commodore 128 (80-col), VIC-20, Atari 8-bit, Atari ST, ZX Spectrum, Amiga, MS-DOS
- **Per-platform colour models** — phosphor radio (Apple II, PET) or full hardware-palette swatch picker (C64, C128, VIC-20, Atari 8-bit, ZX Spectrum, Amiga, Atari ST, MS-DOS) with independent foreground/background selection
- **Per-platform colour memory** — switching platforms restores the colours you last picked for each
- **Live crop tool** — draggable, resizable selection box with locked aspect ratio, rule-of-thirds grid, pinch-zoom, two-finger trackpad pan, mouse-wheel zoom; the converter re-runs as you drag
- **Character picker popover** — every glyph in the current platform's font in a scrollable grid; click to add to a custom ramp, click again to remove
- **PNG export** at 1×, 2×, or 4× the platform's native resolution
- **Bundled fonts:** Pet Me 64, Pet Me 2X, Pet Me 128 2Y, Perfect DOS VGA 437, EightBit Atari, ZX Spectrum, Amiga Topaz, Atari ST 8x16 System Font
- New character ramps: PETSCII Blocks, PETSCII Symbols, CP437 Blocks
- Show 1977 Window and 1977 Help (⌘?) menu commands

### Changed
- Custom ramp text field and preset preview now render in the **current platform's font** (was system monospaced) — Mousetext, PETSCII, block, and box-drawing glyphs render correctly
- Custom-ramp characters that the new platform's font lacks are silently pruned on platform switch (no more "?" boxes)
- Glyph horizontal scaling fix for non-native row counts (e.g. 48 rows on Apple II 40-col): characters now fill their cell width instead of leaving alternating empty stripes

### Fixed
- C64 / MS-DOS fonts not registering at runtime — registration now happens programmatically via `CTFontManagerRegisterFontsForURL` for both `.ttf` and `.otf`
- VIC-20 squeezed horizontally — now uses `Pet Me 2X` for correct double-width pixel aspect (352 × 184)
- Atari ST 3.2 : 1 ultrawide preview — replaced square 8×8 font with a true 8×16 system font for the correct 1.6 : 1 aspect

## [1.0.0] - 2026-05-02

### Added
- Image-to-Apple II ASCII art conversion in 40-column and 80-column modes
- 24-row (one screen) and 48-row (two screens) output sizes
- Four built-in character ramps — Apple II Classic, Standard ASCII, Simple, Dense — plus a custom ramp text field
- Brightness and contrast sliders with live preview (debounced 150 ms)
- Invert toggle for dark-on-light vs light-on-dark output
- Horizontal and vertical flip buttons
- Phosphor screen preview in green (#33FF00), amber (#FFB000), or white
- Authentic Apple II fonts bundled — PrintChar21 (40-col) and PRNumber3 (80-col) from [kreativekorp](https://www.kreativekorp.com/software/fonts/apple2/)
- Apple II screen aspect ratio preserved (280 × 192 display, BT.709 perceptual luminance sampling)
- Drag-and-drop image import (PNG, JPEG, TIFF, GIF, BMP, HEIC)
- Open Image file picker (⌘O)
- Copy ASCII art to clipboard (⇧⌘C)
- Export to Apple II text (`.txt` with CR / 0x0D line endings, 7-bit ASCII)
- Export to Mac text (`.txt` with LF line endings, UTF-8)
- Export to Applesoft BASIC (`.bas` PRINT program, auto-inserts `PR#3` for 80-col)
- App sandbox enabled with user-selected files read/write entitlement
