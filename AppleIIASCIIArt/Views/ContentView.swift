import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var vm = ConverterViewModel()
    @ObservedObject private var appSettings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            SettingsPanel(vm: vm)

            VStack(spacing: 0) {
                PreviewView(vm: vm)

                // Status bar — fixed height so the appearance/disappearance
                // of the converting spinner doesn't grow the bar and shove
                // the preview up.
                HStack(spacing: 12) {
                    if vm.isConverting {
                        ProgressView().scaleEffect(0.6)
                    }
                    if let result = vm.result {
                        Text("\(result.columns) × \(result.rows) characters")
                            .font(.system(size: 11, design: .monospaced))   // keep monospaced for the numeric readout
                            .chromeForeground(.secondary)
                    } else {
                        Text("No image loaded")
                            .chromeFont(.footnote)
                            .chromeForeground(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(statusBarBackgroundColor)
                .overlay(Divider(), alignment: .top)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar { toolbarContent }
        .sheet(isPresented: $vm.showExportSheet) {
            ExportSheet(vm: vm)
        }
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        // Full-window drag & drop
        .onDrop(
            of: [.fileURL, .image, .png, .jpeg, .tiff, .gif, .bmp, .heic],
            isTargeted: nil
        ) { providers in
            vm.loadDroppedProviders(providers)
            return true
        }
        // Tint the title-bar to match the active theme so it doesn't sit as
        // a stark macOS-grey strip above a green / blue / cyan / amber app.
        .background(
            WindowChromeTinter(theme: appSettings.theme)
        )
    }

    /// Themed status-bar fill — falls back to the system window background
    /// under the System theme so the modern look is preserved.
    private var statusBarBackgroundColor: Color {
        ChromeStyle(theme: appSettings.theme).background
            ?? Color(NSColor.windowBackgroundColor)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.showExportSheet = true
            } label: {
                ToolbarButtonLabel(title: "Export", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.result == nil)
            .keyboardShortcut("e", modifiers: .command)
            .help("Export ASCII art")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.copyToClipboard()
            } label: {
                ToolbarButtonLabel(title: "Copy", systemImage: "doc.on.doc")
            }
            .disabled(vm.result == nil)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy to clipboard")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                vm.openImageFilePicker()
            } label: {
                ToolbarButtonLabel(title: "Open Image", systemImage: "photo")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open image file")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "video")
            } label: {
                ToolbarButtonLabel(title: "Convert Movie", systemImage: "film")
            }
            .keyboardShortcut("m", modifiers: .command)
            .help("Convert movie to ASCII art")
        }
    }
}

// MARK: - Window chrome tinter

/// Reaches into the underlying NSWindow and recolours the title-bar so it
/// matches the active retro theme.  Without this the title-bar sits as a
/// stark default-grey strip above a green / blue / cyan / amber window.
///
/// Strategy: make the title-bar transparent and set the window's
/// `backgroundColor`, so AppKit blends them.  Restored to defaults under
/// the System theme.
private struct WindowChromeTinter: NSViewRepresentable {
    let theme: UITheme

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { [weak v] in apply(window: v?.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in apply(window: nsView?.window) }
    }

    private func apply(window: NSWindow?) {
        guard let window else { return }
        if theme == .system {
            // Restore defaults — let macOS handle the title-bar.
            window.titlebarAppearsTransparent = false
            window.backgroundColor = nil
            window.styleMask.remove(.fullSizeContentView)
            return
        }
        // Tint the title-bar with the sidebar colour — matches the strip
        // immediately under it on every retro skin (subtle green tint on
        // Apple II, lighter cyan on VIC-20, etc.) instead of the deeper
        // main-area black.
        let chrome = ChromeStyle(theme: theme)
        guard let bg = chrome.sidebarBackground ?? chrome.background else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(bg)
        window.styleMask.insert(.fullSizeContentView)
    }
}
