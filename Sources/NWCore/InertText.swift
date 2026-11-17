/// Untrusted service text, made inert for display (D-016).
///
/// Log lines and check details come from services that log what their
/// targets said; they are untrusted. Terminal escape sequences, C0/C1 control
/// characters, bidi overrides and isolates, and invisible formatting
/// characters are replaced by visible `\u{XX}` escapes, so a line can never
/// display something other than what it contains. A literal backslash is
/// doubled, which keeps every escape unambiguous. Nothing here interprets
/// markup: views show the result with `Text(verbatim:)`.
public enum InertText {
  /// Longest rendering kept, in Unicode scalars. Longer text is cut and the
  /// cut is stated, never hidden.
  public static let defaultMaxScalars = 4_096

  /// - Parameter multiline: keep `\n` as a line break (detail views). A list
  ///   row passes `false`, so one event can never draw a second, forged row.
  public static func render(
    _ raw: String, multiline: Bool = false, maxScalars: Int = defaultMaxScalars
  ) -> String {
    if isPlainASCII(raw, maxScalars: maxScalars) { return raw }
    var out = String.UnicodeScalarView()
    var kept = 0
    var total = 0
    for scalar in raw.unicodeScalars {
      total += 1
      guard kept < maxScalars else { continue }
      kept += 1
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
    let v = scalar.value
    switch v {
    case 0x09: return false  // tab
    case 0x0A: return !multiline  // newline
    case 0x00...0x1F, 0x7F: return true  // C0 controls (ESC included), DEL
    case 0x80...0x9F: return true  // C1 controls (U+009B is a one-byte CSI)
    case 0x061C, 0x200E, 0x200F: return true  // bidi marks (ALM, LRM, RLM)
    case 0x202A...0x202E: return true  // bidi embeddings and overrides
    case 0x2066...0x2069: return true  // bidi isolates
    case 0x200B...0x200D, 0x2060...0x2064, 0xFEFF: return true  // zero-width / invisible
    case 0x2028, 0x2029: return true  // line and paragraph separators
    case 0xFFF9...0xFFFB: return true  // interlinear annotation
    case 0xE0000...0xE007F: return true  // tag characters (invisible text)
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
