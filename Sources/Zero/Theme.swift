import SwiftUI

/// The design system, from `docs/DESIGN.md`.
///
/// Everything that document states as a rule lives here as a token, because the version where the
/// rules were prose and the values were literals had already drifted: DESIGN.md documented a radius
/// scale of 22 / 14 / 6-8 / capsule while the views used 22, 14, 10, 8, 6 and 4, and the 820pt
/// measure was a literal repeated at four call sites next to a fifth, undocumented 620.
///
/// `Scripts/lint-design-tokens.sh` is what keeps that from happening again — it fails the build on a
/// literal radius, measure or surface opacity in `Sources/Zero`. A token without enforcement is a
/// convention, and a convention is what drifted.
enum Theme {

    // MARK: - Palette

    /// Neither pure black nor pure white appears anywhere: `ink` on `paper` measures 16.74:1, against
    /// 21:1 for `#000`/`#fff` — below the theoretical maximum and well past the 7:1 that WCAG AAA
    /// asks for. Deployment target is macOS 15.0; nothing here is exclusive to a newer macOS, so
    /// there are no availability branches.
    static let ink = Color(red: 0x13 / 255, green: 0x13 / 255, blue: 0x13 / 255)
    static let paper = Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF3 / 255)

    /// Secondary text opacity floor.
    ///
    /// 70% of `paper` on `ink` is 7.91:1 and still clears AAA. At 55% it falls to 5.10:1, which only
    /// clears AA — so this is a floor, not a suggestion. Anything dimmer needs a different approach,
    /// not a smaller number.
    static let secondaryOpacity: Double = 0.7

    /// The one hue in the app. Its primary job is "the agent is waiting for you", marking
    /// `StateDot` when `awaiting` is true and the pending permission surface — not primary actions
    /// (fill already says that), not session state, not links.
    ///
    /// **One deliberate, documented exception:** the usage ring's filled arc (`UsageIndicator`)
    /// also uses this token, opacity-graded by context severity (`011-usage-ring-color`, amending
    /// FR-8 of `004-ui-visual-overhaul` after that PRD had already shipped — see that PRD's FR-8 for
    /// the amendment note). `Scripts/lint-design-tokens.sh` counts exactly these three files, plus
    /// this one where the token is defined; a fourth use anywhere else fails the build.
    ///
    /// It is never the only carrier of that meaning, in either use. The dot keeps its ring, the card
    /// keeps its shape, and the ring keeps its fraction and opacity step, so the same information
    /// arrives without perceiving the hue at all (WCAG 1.4.1) — which is what lets a hue exist here
    /// without breaking the accessibility argument the monochrome rule was built on.
    ///
    /// **Chosen by eye, then measured.** `#8B5CF6` is 4.39:1 against `ink` and 3.82:1 against
    /// `paper`. It never renders text, so the threshold that applies is the 3:1 of WCAG 1.4.11 for
    /// non-text contrast, and it clears that in both themes.
    ///
    /// It is not the balance point — a single colour sitting between two backgrounds 16.74:1 apart
    /// maximises its weaker side at 4.09:1, and this trades some of the light-mode side for the hue
    /// that was wanted. 3.82:1 is still comfortably above the bar, so the trade is affordable; the
    /// number is written down so the next person changing this knows where the floor is.
    ///
    /// One value rather than one per theme, deliberately: a hue that shifts with the theme is a
    /// second thing to keep measured.
    static let accent = Color(red: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255)

    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? ink : paper
    }

    static func foreground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? paper : ink
    }

    /// How far the selected row's fill steps back off full foreground weight.
    ///
    /// Full `ink` under a sidebar row reads as a hole punched in the window rather than as a
    /// selection — the one place in this app where the foreground token covers an area instead of
    /// drawing on one, and at that size it is simply too heavy.
    ///
    /// A **mix**, not an opacity: this fill's other job is to cover AppKit's own highlight (see
    /// `SessionSidebar`), and 10% of translucency is 10% of that blue coming through. Mixed, the
    /// light-mode fill is `#292929` and the dark-mode fill `#dcdcdc`, and the row on it measures
    /// 13.0:1 for the title in either theme, 7.2:1 (light) and 6.0:1 (dark) for the summary at the
    /// 70% floor — the same asymmetry the floor already has everywhere else in the app.
    static let selectionSoftening: Double = 0.10

    /// The fill for a selected sidebar row: the foreground token, softened toward the background.
    static func rowSelection(_ scheme: ColorScheme) -> Color {
        // `.device` rather than the default perceptual space: this is a straight sRGB step between
        // two known values, so the result is the hex written above rather than whatever Oklab makes
        // of it — a value in this file should be one you can check with a colour picker.
        foreground(scheme).mix(with: background(scheme), by: selectionSoftening, in: .device)
    }

    /// The foreground for content on a selected sidebar row.
    ///
    /// Left alone, AppKit fills a selected row with the *system* accent colour — a saturated blue
    /// nobody here chose, that answers to no measurement in this document, and that changes under
    /// the app when the user picks a different one in System Settings. In light mode it puts `paper`
    /// at 4.6:1 and the accent dot at 1.2:1, in a palette whose whole argument is 16.74:1 and one
    /// hue. `SessionSidebar` paints that fill itself instead, with the foreground token.
    ///
    /// So a selected row **inverts**: the fill is the foreground token, so the content on it is the
    /// background token — back at the same 16.74:1 as every other surface in the app, with the
    /// ordinary 70% floor for the summary underneath it.
    ///
    /// Selection is passed in rather than read from `backgroundProminence`, which is what an earlier
    /// version did: supplying a `.listRowBackground` is what covers AppKit's fill, and doing so also
    /// makes the platform stop reporting the row as prominent. The environment then describes a
    /// treatment that is no longer on screen, so the row that is painted ink read itself as
    /// unselected and drew ink on ink. What we paint is what we have to answer to.
    static func rowForeground(_ scheme: ColorScheme, selected: Bool) -> Color {
        selected ? background(scheme) : foreground(scheme)
    }

    /// The row foreground at the secondary floor. The same 70% that applies everywhere else, which
    /// it can be again now that the fill under it is a token rather than the system accent.
    static func rowSecondary(_ scheme: ColorScheme, selected: Bool) -> Color {
        rowForeground(scheme, selected: selected).opacity(secondaryOpacity)
    }

    /// The foreground at the secondary floor. Its own function because it is the single most repeated
    /// expression in the app, and spelling it out at every call site is how a hand-picked grey slips
    /// in below the floor.
    static func secondary(_ scheme: ColorScheme) -> Color {
        foreground(scheme).opacity(secondaryOpacity)
    }

    // MARK: - Syntax

    /// Color for the file-tree preview's syntax highlighting
    /// (`docs/prds/007-file-tree-sidebar/PRD.md` FR-6) — the one place in this app text is colored
    /// by token. Added after Gate 3 at the user's explicit request ("vercel code theme"), reversing
    /// that PRD's original monochrome-only preview.
    ///
    /// Deliberately **not** the accent color above: that one means one specific thing ("the agent
    /// is waiting for you") and `Scripts/lint-design-tokens.sh` counts its every use — reusing it
    /// here would make that count lie. This is its own small, separate palette, chosen to read
    /// clearly against both `ink` and `paper` without being mistaken for the accent's violet. `.comment`
    /// isn't a color at all — it reuses `Theme.secondary`, a dimmed line being exactly what a
    /// comment already means everywhere else text is de-emphasized in this app.
    ///
    /// Doubles as the file tree's git-diff palette (`.added`/`.modified`, same green/amber as
    /// `.string`/`.number` — the file tree marks a new file the same green a highlighted string
    /// reads as, and a changed one the same amber a highlighted number does, rather than adding a
    /// third small palette for what is, visually, the same kind of thing: content-level
    /// colorization, distinct from the app's one UI-status accent).
    enum Syntax {
        static func keyword(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0xF9 / 255, green: 0x7A / 255, blue: 0xD6 / 255)
                : Color(red: 0xB8 / 255, green: 0x1B / 255, blue: 0x7A / 255)
        }

        static func string(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0x7E / 255, green: 0xE7 / 255, blue: 0x87 / 255)
                : Color(red: 0x1A / 255, green: 0x7A / 255, blue: 0x3A / 255)
        }

        static func number(_ scheme: ColorScheme) -> Color {
            scheme == .dark
                ? Color(red: 0xF3 / 255, green: 0xB0 / 255, blue: 0x5C / 255)
                : Color(red: 0xA5 / 255, green: 0x5A / 255, blue: 0x00 / 255)
        }

        /// A new/untracked file or folder in the file tree. Same value as `.string` — see the
        /// type's doc comment.
        static func added(_ scheme: ColorScheme) -> Color { string(scheme) }

        /// A file or folder with uncommitted changes in the file tree. Same value as `.number`.
        static func modified(_ scheme: ColorScheme) -> Color { number(scheme) }
    }

    // MARK: - Type

    /// The face for anything that is code: a path, a command, a diff, a tool name, a model id.
    ///
    /// One helper instead of `.callout.monospaced()` written out at nine call sites, so "what does
    /// code look like here" is answered in one place and every code surface answers it the same way.
    ///
    /// **On the alternate zero.** FR-12 asked for the alternate-zero stylistic set, on the reasoning
    /// that `0`/`O` and `1`/`l`/`I` must be distinguishable at body size. Measuring the font first
    /// (see `docs/prds/004-ui-visual-overhaul/TESTING.md`) inverted the requirement: the monospaced
    /// system face already ships the slashed zero as its *default* glyph, and the stylistic set on
    /// offer — type 35, selector 6 — is named "Alternate 0 no slash", i.e. it takes the slash away.
    /// The default glyphs for `0`, `O`, `1`, `l` and `I` are already five distinct glyph ids.
    ///
    /// So the requirement's intent is met by changing nothing about the glyphs, and the thing worth
    /// enforcing is what this helper actually does: that every code surface goes through one font,
    /// and that nobody enables selector 6 later thinking it improves legibility.
    static func code(_ style: Font.TextStyle = .callout, weight: Font.Weight? = nil) -> Font {
        let font = Font.system(style, design: .monospaced)
        return weight.map { font.weight($0) } ?? font
    }

    /// The display treatment, for the two places a screen asks you something and has nothing else
    /// on it: the `ComposeView` headline and `EmptyStatePane`.
    ///
    /// Still the system font — a second family for prose is not on the table — but at a scale and a
    /// tracking that prose never uses. `.title2.weight(.medium)` read as a form label because it is
    /// the size a form label is; going up two steps and tightening the tracking is what makes the
    /// same sentence read as the thing the screen is for.
    static func display(_ style: Font.TextStyle = .largeTitle) -> Font {
        .system(style, design: .default).weight(.semibold)
    }

    /// Paired with `display`. Negative because large type set at prose tracking looks loose, and
    /// tightening it is most of what separates a headline from a big label.
    static let displayTracking: CGFloat = -0.5

    // MARK: - Motion

    /// The four durations this app animates at. Every animation is one of these, and every one of
    /// them is reporting a state change or a piece of feedback — nothing here is decoration, and
    /// nothing repeats forever.
    enum Motion {
        /// Feedback on a control you are touching right now: a focus ring, a hover fill.
        static let feedback = Animation.easeOut(duration: 0.1)
        /// A value moving to a new value: the usage arc, a tool call changing state.
        static let value = Animation.easeOut(duration: 0.25)
        /// Something arriving on screen: the permission card, a new line of diff.
        static let arrival = Animation.easeOut(duration: 0.2)
        /// The transcript following the conversation down.
        static let scroll = Animation.easeOut(duration: 0.15)

        /// The window a staggered entry spreads over, regardless of how many items are in it — so a
        /// forty-line diff does not take four seconds to finish arriving.
        static let stagger: Double = 0.2
    }

    // MARK: - Radius

    /// Corner radius says what kind of thing something is. Four values, no fifth.
    enum Radius {
        /// The composer and its equivalent in `ComposeView`. The one thing you type into.
        static let composer: CGFloat = 22
        /// The permission card. A decision, not a message.
        static let card: CGFloat = 14
        /// A surface holding content: code blocks, diff containers, the user's own message.
        static let content: CGFloat = 8
        /// Chrome around content: tool call cells, the search field.
        static let inline: CGFloat = 6
    }

    // MARK: - Measure

    /// A measure, not the window. Text running edge-to-edge on a wide display is most of what makes
    /// a chat feel like a log file rather than a conversation.
    static let measure: CGFloat = 820

    /// Narrower, for the single question `ComposeView` asks.
    static let composeMeasure: CGFloat = 620

    // MARK: - Fill

    /// Surface fills, as a fraction of the foreground token.
    ///
    /// The pre-token code had 0.04, 0.045, 0.055, 0.06, 0.08 and 0.10 in circulation. Values 0.005
    /// apart were not communicating anything a reader could perceive. What survived is the set
    /// `Elevation` needs — one value per level — plus the one fill that is feedback rather than a
    /// surface.
    enum Fill {
        /// A well inside another surface: code blocks, the permission detail.
        static let sunken: Double = 0.04
        /// A surface sitting on the canvas: the composer, a tool call, the user's own message.
        static let raised: Double = 0.055
        /// A surface that has arrived over everything else. Far enough from `raised` to still read
        /// as a level above it when the material is gone.
        static let floating: Double = 0.10
        /// Pointer feedback on an outlined control. Not a surface — it comes and goes with the
        /// pointer, which is why it is not an elevation.
        static let hover: Double = 0.10
    }

    // MARK: - Elevation

    /// How far off the canvas a surface sits. Four levels, and a view picks one rather than picking
    /// a fill: "this has arrived over the conversation" is the decision, and the material, the
    /// opacity and the shadow all follow from it.
    ///
    /// Above `canvas` the levels are drawn with native macOS materials, so a surface picks up the
    /// vibrancy of what is behind it instead of being a flat grey rectangle — which is the whole
    /// reason to have levels rather than three hand-tuned opacities. Under
    /// `accessibilityReduceTransparency` every level falls back to a solid fill chosen to keep the
    /// same separation between adjacent levels (see `opaqueFill`).
    enum Elevation {
        /// The page itself: the window background, the sidebar, the transcript. No surface of its
        /// own — it is what the other levels sit on.
        case canvas
        /// A well inside another surface. Recedes, so it never competes with the surface holding it.
        case sunken
        /// Sitting on the canvas, and you act on it or read content out of it.
        case raised
        /// Arrived over everything else, and holds the interaction until it is answered.
        case floating

        /// `nil` for `canvas`, which has no surface, and for `sunken`, which sits inside one — there
        /// is nothing behind a well to blur, so a material there costs a layer and buys nothing.
        var material: Material? {
            switch self {
            case .canvas, .sunken: nil
            case .raised: .regularMaterial
            case .floating: .thickMaterial
            }
        }

        /// The solid fill, as a fraction of the foreground token, used both for `sunken` and as the
        /// `accessibilityReduceTransparency` fallback for every level.
        var opaqueFill: Double? {
            switch self {
            case .canvas: nil
            case .sunken: Fill.sunken
            case .raised: Fill.raised
            case .floating: Fill.floating
            }
        }

        /// Only `floating` casts one, and softly: a shadow here says "this is over the thing you
        /// were reading", not "this is a card in a stack of cards".
        var shadow: (opacity: Double, radius: CGFloat, y: CGFloat)? {
            switch self {
            case .canvas, .sunken, .raised: nil
            case .floating: (0.18, 14, 5)
            }
        }
    }

    /// Diff line tints. Monochrome on purpose: added and removed are told apart by the `+`/`−`
    /// marker and by a tint of the single foreground token, never by red and green.
    enum Diff {
        static let removed: Double = 0.10
        static let added: Double = 0.04
    }

    // MARK: - Mark

    /// Weights for a mark — a status dot, a gauge arc — as a fraction of the foreground token.
    ///
    /// A mark is not a surface: it sits on top of one, and it carries meaning by weight because this
    /// palette has no hue to carry it with.
    enum Mark {
        /// A gauge arc below its warning threshold.
        static let gauge: Double = 0.75
        /// A mark standing in for a value the provider never gave us.
        static let unknown: Double = 0.35
        /// FR-31 of `001-agent-chat-core`: the fraction of the context window past which the arc
        /// goes to full weight, because "nearly full" is the one reading worth interrupting for.
        static let gaugeWarning: Double = 0.85
    }

    // MARK: - Stroke

    /// Border weights, as a fraction of the foreground token.
    ///
    /// `hairline` replaced five values between 0.12 and 0.18 that all meant "a faint border" and
    /// differed only by which file they were written in.
    enum Stroke {
        /// The default border for any content surface.
        static let hairline: Double = 0.15
        /// An outlined interactive control: the permission pills, the mode pills.
        static let control: Double = 0.22
        /// A focused text field.
        static let focus: Double = 0.32
        /// The unfilled part of a gauge, which is a track rather than a border.
        static let track: Double = 0.18
    }
}

// MARK: - Modifiers

extension View {
    /// Applies the palette, so no view has to decide what "background" means.
    func zeroSurface(_ scheme: ColorScheme) -> some View {
        self
            .background(Theme.background(scheme))
            .foregroundStyle(Theme.foreground(scheme))
    }

    /// A rounded surface at a named elevation — the shape this app builds almost everything out of.
    ///
    /// One modifier instead of the `.background(RoundedRectangle…fill)` plus
    /// `.overlay(RoundedRectangle…stroke)` pair repeated at eight call sites, each of which had to
    /// restate the radius twice and could get the two out of step. Call sites name a level, not a
    /// number: see `Theme.Elevation`.
    func zeroPanel(
        _ scheme: ColorScheme,
        radius: CGFloat,
        elevation: Theme.Elevation = .raised,
        stroke: Double? = Theme.Stroke.hairline
    ) -> some View {
        modifier(ZeroPanel(scheme: scheme, radius: radius, elevation: elevation, stroke: stroke))
    }

    /// Caps the content at a measure and centers it in whatever space is left.
    ///
    /// Replaces the `.frame(maxWidth: N).frame(maxWidth: .infinity)` idiom, which reads as a mistake
    /// until you know it is the way to say "this wide, centered".
    func zeroMeasure(_ width: CGFloat = Theme.measure) -> some View {
        self
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
    }
}

/// The body of `zeroPanel`, as a `ViewModifier` because it has to read the environment: whether the
/// user has asked for reduced transparency decides between a material and a solid fill, and that
/// question cannot be answered from inside a `View` extension.
private struct ZeroPanel: ViewModifier {
    let scheme: ColorScheme
    let radius: CGFloat
    let elevation: Theme.Elevation
    let stroke: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return content
            .background {
                // The material when there is one and transparency is welcome; otherwise the solid
                // fill for this level, which is picked to preserve the separation the material gave.
                if let material = elevation.material, !reduceTransparency {
                    shape.fill(material)
                } else if let fill = elevation.opaqueFill {
                    shape.fill(Theme.foreground(scheme).opacity(fill))
                }
            }
            .overlay {
                if let stroke {
                    shape.stroke(Theme.foreground(scheme).opacity(stroke), lineWidth: 1)
                }
            }
            .modifier(ZeroShadow(shadow: elevation.shadow))
    }
}

/// Split out so the `nil` case adds no modifier at all rather than a shadow of radius zero.
private struct ZeroShadow: ViewModifier {
    let shadow: (opacity: Double, radius: CGFloat, y: CGFloat)?

    func body(content: Content) -> some View {
        if let shadow {
            // Always cast from `ink`, in both themes: a shadow is an absence of light, and tinting
            // it with the foreground would make it glow in dark mode.
            content.shadow(
                color: Theme.ink.opacity(shadow.opacity),
                radius: shadow.radius,
                y: shadow.y
            )
        } else {
            content
        }
    }
}

/// Animates only if the user has not asked for less motion.
///
/// `accessibilityReduceMotion` is a system setting that this app had no reference to at all before
/// the overhaul, while claiming keyboard and accessibility parity. One modifier rather than an
/// environment read in every view, so honouring it is the default and forgetting it takes effort.
private struct ZeroMotion<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)  // design-token-lint:allow — this is the helper
    }
}

extension View {
    /// The one way this app animates a state change. See `Theme.Motion`.
    func zeroAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ZeroMotion(animation: animation, value: value))
    }
}
