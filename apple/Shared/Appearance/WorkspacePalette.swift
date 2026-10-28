import SwiftUI

/// Neutral light/dark surfaces. Terminal surfaces are always opaque.
struct WorkspacePalette {
  let scheme: ColorScheme
  var canvas: Color {
    scheme == .dark ? Color(white: 0.035) : .white
  }
  var panel: Color {
    scheme == .dark ? Color(white: 0.065) : .white
  }
  var sidebar: Color {
    scheme == .dark ? Color(white: 0.045) : Color(white: 0.975)
  }
  var raised: Color {
    scheme == .dark ? Color(white: 0.105) : Color(white: 0.965)
  }
  var selection: Color {
    scheme == .dark ? Color(white: 0.15) : Color(white: 0.92)
  }
  var terminal: Color {
    scheme == .dark ? Color(red: 24 / 255.0, green: 24 / 255.0, blue: 37 / 255.0) : .white
  }
  var terminalText: Color {
    scheme == .dark ? Color(white: 0.92) : Color(white: 0.1)
  }
  var terminalSecondary: Color {
    scheme == .dark ? Color(white: 0.65) : Color(white: 0.4)
  }
  var accent: Color {
    scheme == .dark ? Color(white: 0.93) : Color(white: 0.12)
  }
  var onAccent: Color {
    scheme == .dark ? .black : .white
  }
  var border: Color {
    scheme == .dark ? Color(white: 0.18) : Color(white: 0.89)
  }
}
