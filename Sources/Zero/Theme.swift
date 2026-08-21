import SwiftUI

/// The palette, from the logo. Two tokens, whose roles swap with the theme.
///
/// Neither pure black nor pure white appears anywhere: `ink` on `paper` measures 16.74:1, against
/// 21:1 for `#000`/`#fff` — below the theoretical maximum and well past the 7:1 that WCAG AAA asks
/// for. Deployment target is macOS 26, so there are no availability branches to work around here.
enum Theme {
    static let ink = Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x13 / 255)
    static let paper = Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF3 / 255)

    /// Secondary text opacity floor.
    ///
    /// 70% of `paper` on `ink` is 7.91:1 and still clears AAA. At 55% it falls to 5.10:1, which only
    /// clears AA — so this is a floor, not a suggestion. Anything dimmer needs a different approach,
    /// not a smaller number.
    static let secondaryOpacity: Double = 0.7
    static let tertiaryOpacity: Double = 0.7

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ink : paper
    }

    static func foreground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? paper : ink
    }
}

extension View {
    /// Applies the palette, so no view has to decide what "background" means.
    func zeroSurface(_ scheme: ColorScheme) -> some View {
        self
            .background(Theme.background(scheme))
            .foregroundStyle(Theme.foreground(scheme))
    }
}
