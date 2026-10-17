import SwiftUI

/// Semantic role of a piece of chrome text. Each role maps to a base point
/// size; the actual `Font` is resolved per-theme by `ChromeStyle`.
enum ChromeRole {
    case headline   // section titles
    case body       // standard labels
    case caption    // small hints
    case footnote   // status bar / tiny text

    var systemSize: CGFloat {
        switch self {
        case .headline: return 13
        case .body:     return 12
        case .caption:  return 11
        case .footnote: return 11
        }
    }
}

enum ChromeForegroundKind { case primary, secondary }
enum ChromeBackgroundKind { case main, sidebar }

/// Pure value type that translates a `UITheme` into the concrete `Font` and
/// `Color` values consumed by the chrome view modifiers.
///
/// For `.system`, color accessors return `nil` — the modifiers fall back to
/// SwiftUI's default colors so the modern macOS look is preserved exactly.
struct ChromeStyle {
    let theme: UITheme

    func font(_ role: ChromeRole) -> Font {
        let size = role.systemSize + theme.fontSizeBoost
        if let name = theme.fontName {
            return .custom(name, size: size)
        }
        return role == .headline
            ? .system(size: size, weight: .semibold)
            : .system(size: size)
    }

    var background: Color? {
        switch theme.family {
        case .system:    return nil
        case .appleII:   return AppleIIThemeColors.background
        case .appleIIgs: return AppleIIgsThemeColors.background
        case .commodore: return C64ThemeColors.background
        case .vic20:     return VIC20ThemeColors.background
        case .msDOS:     return DOSThemeColors.background
        }
    }

    var sidebarBackground: Color? {
        switch theme.family {
        case .system:    return nil
        case .appleII:   return AppleIIThemeColors.secondaryBg
        case .appleIIgs: return AppleIIgsThemeColors.secondaryBg
        case .commodore: return C64ThemeColors.secondaryBg
        case .vic20:     return VIC20ThemeColors.secondaryBg
        case .msDOS:     return DOSThemeColors.secondaryBg
        }
    }

    var foreground: Color? {
        switch theme.family {
        case .system:    return nil
        case .appleII:   return AppleIIThemeColors.text
        case .appleIIgs: return AppleIIgsThemeColors.text
        case .commodore: return C64ThemeColors.text
        case .vic20:     return VIC20ThemeColors.text
        case .msDOS:     return DOSThemeColors.text
        }
    }

    var dimForeground: Color? {
        switch theme.family {
        case .system:    return nil
        case .appleII:   return AppleIIThemeColors.dimText
        case .appleIIgs: return AppleIIgsThemeColors.dimText
        case .commodore: return C64ThemeColors.dimText
        case .vic20:     return VIC20ThemeColors.dimText
        case .msDOS:     return DOSThemeColors.dimText
        }
    }

    var border: Color? {
        switch theme.family {
        case .system:    return nil
        case .appleII:   return AppleIIThemeColors.border
        case .appleIIgs: return AppleIIgsThemeColors.border
        case .commodore: return C64ThemeColors.border
        case .vic20:     return VIC20ThemeColors.border
        case .msDOS:     return DOSThemeColors.border
        }
    }
}

// MARK: - View modifiers

extension View {
    func chromeFont(_ role: ChromeRole) -> some View {
        modifier(ChromeFontModifier(role: role))
    }

    func chromeForeground(_ kind: ChromeForegroundKind = .primary) -> some View {
        modifier(ChromeForegroundModifier(kind: kind))
    }

    func chromeBackground(_ kind: ChromeBackgroundKind = .main) -> some View {
        modifier(ChromeBackgroundModifier(kind: kind))
    }
}

private struct ChromeFontModifier: ViewModifier {
    @ObservedObject var settings = AppSettings.shared
    let role: ChromeRole
    func body(content: Content) -> some View {
        content.font(ChromeStyle(theme: settings.theme).font(role))
    }
}

private struct ChromeForegroundModifier: ViewModifier {
    @ObservedObject var settings = AppSettings.shared
    let kind: ChromeForegroundKind
    func body(content: Content) -> some View {
        let style = ChromeStyle(theme: settings.theme)
        let themed = (kind == .primary) ? style.foreground : style.dimForeground
        if let themed {
            content.foregroundColor(themed)
        } else {
            content.foregroundColor(kind == .primary ? .primary : .secondary)
        }
    }
}

private struct ChromeBackgroundModifier: ViewModifier {
    @ObservedObject var settings = AppSettings.shared
    let kind: ChromeBackgroundKind
    @ViewBuilder
    func body(content: Content) -> some View {
        let style = ChromeStyle(theme: settings.theme)
        let themed = (kind == .main) ? style.background : style.sidebarBackground
        if let themed {
            content.background(themed)
        } else {
            content
        }
    }
}

// MARK: - Toolbar buttons

/// Label for a toolbar button: a large icon with its name underneath, so
/// the action is clear without hovering for a tooltip. Used by both the
/// image and video windows. Disabled buttons dim automatically.
struct ToolbarButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 21))
                .frame(height: 24)
            Text(title)
                .chromeFont(.footnote)
                .lineLimit(1)
        }
        .frame(minWidth: 62)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
