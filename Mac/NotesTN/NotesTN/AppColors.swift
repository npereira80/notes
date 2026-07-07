import SwiftUI

// MARK: - Brand yellow palette
// Single source of truth for the four approved yellow shades (same values in
// light and dark mode — see Android's ui/theme/Color.kt AppColors object and
// the --color-* custom properties in Mac/EditorBundle/build.mjs for the
// mirrored definitions used by the shared ProseMirror editor).
enum AppColors {
    /// Selected notebook row (sidebar) while the sidebar itself has keyboard focus;
    /// also new note/new notebook buttons.
    static let vividYellow = Color(red: 0xF9 / 255, green: 0xB5 / 255, blue: 0x24 / 255)          // #F9B524

    /// Main tint/accent color, text caret, modal text buttons, active text field;
    /// also the text color of a selected-but-unfocused sidebar row (see
    /// sidebarSelectedInactiveBackground below).
    static let darkYellow = Color(red: 0xDE / 255, green: 0xAA / 255, blue: 0x33 / 255)           // #DEAA33

    /// Selected note row background whenever the sidebar does NOT have focus
    /// (i.e. focus is in the note list or the editor).
    static let dimmedYellow = Color(red: 0xFB / 255, green: 0xE6 / 255, blue: 0x99 / 255)         // #FBE699

    /// Text selection highlight inside the editor.
    static let textSelectYellow = Color(red: 0xFA / 255, green: 0xEB / 255, blue: 0xC3 / 255)     // #FAEBC3

    /// Selected notebook row background when the sidebar does NOT have focus.
    static func sidebarSelectedInactiveBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x26 / 255, green: 0x29 / 255, blue: 0x29 / 255)   // #262929
            : Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)   // #EEEEEE
    }

    /// Selected note row background when the sidebar DOES have focus.
    static func noteRowSelectedInactiveBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x47 / 255, green: 0x45 / 255, blue: 0x46 / 255)   // #474546
            : Color(red: 0xDD / 255, green: 0xDC / 255, blue: 0xDC / 255)   // #DDDCDC
    }
}
