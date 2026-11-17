import AppKit
import NWCore
import SwiftUI

/// The bounded event list as an AppKit table (newest first).
///
/// `NSTableView` asks only for the rows on screen, and `reloadData` costs
/// the visible rows, not the 10,000 behind them — the main actor's work per
/// batch no longer grows with the history. (The profiling drill that found
/// the SwiftUI `List` version stalling the main thread is in
/// `perf/results/app/README.md`; `NW_EVENT_LIST=swiftui-list` brings that
/// version back to reproduce it.) Cells are plain-text `NSTextField`s set
/// through `stringValue`: no attributed text, no markup, no links (D-016).
struct EventTable: NSViewRepresentable {
  let rows: [EventRow]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let table = NSTableView()
    table.style = .fullWidth
    table.usesAlternatingRowBackgroundColors = true
    table.rowHeight = 18
    table.usesAutomaticRowHeights = false
    table.allowsColumnReordering = false
    table.allowsMultipleSelection = false
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    for (id, title, width) in Coordinator.columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = min(width, 40)
      column.resizingMask = id == "text" ? .autoresizingMask : .userResizingMask
      table.addTableColumn(column)
    }
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    table.setAccessibilityLabel("Events, newest first")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.rows = rows
    (scroll.documentView as? NSTableView)?.reloadData()
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let columns: [(String, String, CGFloat)] = [
      ("time", "Time", 150), ("severity", "", 22), ("service", "Service", 120),
      ("text", "Event", 600),
    ]
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    /// Oldest first; row 0 on screen is the newest.
    var rows: [EventRow] = []

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
      guard let column, row < rows.count else { return nil }
      let event = rows[rows.count - 1 - row]
      let id = column.identifier
      let field =
        tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
        ?? {
          let field = NSTextField(labelWithString: "")
          field.identifier = id
          field.font = Self.font
          field.lineBreakMode = .byTruncatingTail
          field.maximumNumberOfLines = 1
          field.allowsEditingTextAttributes = false
          field.isSelectable = true
          field.clipsToBounds = true  // nothing a cell holds can draw over its neighbours
          return field
        }()
      switch id.rawValue {
      case "time":
        field.stringValue = event.time
        field.textColor = .secondaryLabelColor
      case "severity":
        field.stringValue = Self.glyph(event)
        field.textColor = Self.color(event)
        field.setAccessibilityLabel(event.isGap ? "gap" : event.severity.rawValue)
      case "service":
        field.stringValue = event.service.rawValue
        field.textColor = .secondaryLabelColor
      default:
        field.stringValue = event.text  // already inert (InertText), plain string
        field.textColor = event.isGap ? .systemOrange : .labelColor
      }
      return field
    }

    static func glyph(_ row: EventRow) -> String {
      if row.isGap { return "✂︎" }
      switch row.severity {
      case .ok: return "✓"
      case .info: return "·"
      case .warning: return "!"
      case .failure: return "✗"
      case .unknown: return "?"
      }
    }

    static func color(_ row: EventRow) -> NSColor {
      if row.isGap { return .systemOrange }
      switch row.severity {
      case .ok: return .systemGreen
      case .info: return .secondaryLabelColor
      case .warning: return .systemOrange
      case .failure: return .systemRed
      case .unknown: return .systemYellow
      }
    }
  }
}
