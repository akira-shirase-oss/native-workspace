/// Untrusted service text, made inert for display (D-016).
///
/// Log lines and check details come from services that log what their
/// targets said; they are untrusted. Which scalars are shown as visible
/// `\u{XX}` escapes is decided by Unicode property, not by a hand list:
/// controls (Cc), format characters (Cf), line and paragraph separators,
/// unassigned and private-use code points, noncharacters, and everything
/// Default_Ignorable, Bidi_Control or Variation_Selector — plus the two
/// blank-rendering symbols U+2800 and U+FFFC. So a line can never display
/// something other than what it contains: no terminal escapes, no bidi
/// reordering, no invisible or zero-width text. Combining marks are kept up
/// to `maxCombiningMarks` per base character; further ones are escaped, so a
/// mark flood cannot stack over neighbouring rows. A literal backslash is
/// doubled, which keeps every escape unambiguous. Nothing here interprets
/// markup: views show the result with `Text(verbatim:)` or a plain
/// `NSTextField.stringValue`.
public enum InertText {
  /// Longest rendering kept, in Unicode scalars. Longer text is cut and the
  /// cut is stated, never hidden.
  public static let defaultMaxScalars = 4_096
  /// Combining marks kept after one base character (Vietnamese needs two;
  /// a few more cover the scripts that stack).
  public static let maxCombiningMarks = 4

  /// - Parameter multiline: keep `\n` as a line break (detail views). A list
  ///   row passes `false`, so one event can never draw a second, forged row.
  public static func render(
    _ raw: String, multiline: Bool = false, maxScalars: Int = defaultMaxScalars
  ) -> String {
    if isPlainASCII(raw, maxScalars: maxScalars) { return raw }
    var out = String.UnicodeScalarView()
    var kept = 0
    var total = 0
    var marks = 0
    for scalar in raw.unicodeScalars {
      total += 1
      guard kept < maxScalars else { continue }
      kept += 1
      if isCombiningMark(scalar) {
        marks += 1
        if marks > maxCombiningMarks {
          appendEscape(scalar, to: &out)
          continue
        }
      } else {
        marks = 0
      }
      append(scalar, multiline: multiline, to: &out)
    }
    var result = String(out)
    if total > kept {
      result += " … [\(total - kept) more characters not shown]"
    }
    return result
  }

  /// Whether a scalar is shown as an escape rather than itself.
  public static func mustEscape(_ scalar: Unicode.Scalar, multiline: Bool = false) -> Bool {
    switch scalar.value {
    case 0x09: return false  // tab
    case 0x0A: return !multiline  // newline
    case 0x20...0x7E: return false  // printable ASCII
    case 0x2800, 0xFFFC: return true  // Braille blank, object replacement: render blank
    default: break
    }
    let properties = scalar.properties
    switch properties.generalCategory {
    case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned,
      .privateUse:
      return true
    default:
      break
    }
    return properties.isDefaultIgnorableCodePoint || properties.isBidiControl
      || properties.isVariationSelector || properties.isNoncharacterCodePoint
  }

  static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
    guard scalar.value >= 0x0300 else { return false }
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark: return true
    default: return false
    }
  }

  private static func append(
    _ scalar: Unicode.Scalar, multiline: Bool, to out: inout String.UnicodeScalarView
  ) {
    if scalar == "\\" {
      out.append("\\")
      out.append("\\")
      return
    }
    guard mustEscape(scalar, multiline: multiline) else {
      out.append(scalar)
      return
    }
    appendEscape(scalar, to: &out)
  }

  private static func appendEscape(_ scalar: Unicode.Scalar, to out: inout String.UnicodeScalarView)
  {
    let hex = String(scalar.value, radix: 16, uppercase: true)
    let padded = hex.count < 2 ? "0" + hex : hex
    out.append(contentsOf: "\\u{\(padded)}".unicodeScalars)
  }

  /// Fast path: printable ASCII without a backslash needs no work.
  private static func isPlainASCII(_ raw: String, maxScalars: Int) -> Bool {
    var count = 0
    for byte in raw.utf8 {
      count += 1
      if byte < 0x20 || byte > 0x7E || byte == 0x5C || count > maxScalars { return false }
    }
    return true
  }
}

/// Text from a service, already made inert and bounded. The only way to
/// build one is from untrusted text through `InertText`, so a view that is
/// handed an `InertString` cannot show a raw service string by accident.
public struct InertString: Sendable, Hashable, Codable, CustomStringConvertible {
  public let value: String

  /// - Parameter maxScalars: the rendering's length cap (the cut is stated).
  public init(_ untrusted: String, maxScalars: Int = 256) {
    value = InertText.render(untrusted, multiline: false, maxScalars: maxScalars)
  }

  public var description: String { value }

  public static let empty = InertString("")
}
