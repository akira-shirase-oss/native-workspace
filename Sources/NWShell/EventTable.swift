import AppKit
import NWCore
import SwiftUI

/// The bounded event list as an AppKit table (newest first).
///
/// `NSTableView` asks only for the rows on screen, and `reloadData` costs
/// the visible rows, not the 10,000 behind them — the main actor's work per
/// batch no longer grows with the history. A batch is applied as removals at
/// the bottom and insertions at the top, so the selected event stays
/// selected and a scrolled view keeps the rows being read. (The profiling drill that found
/// the SwiftUI `List` version stalling the main thread is in
/// `perf/results/README.md`, *App*; `NW_EVENT_LIST=swiftui-list` brings that
/// version back to reproduce it.) Cells are plain-text `NSTextField`s set
/// through `stringValue`: no attributed text, no markup, no links (D-016).
struct EventTable: NSViewRepresentable {
  let rows: [EventRow]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    Self.makeScrollView(coordinator: context.coordinator)
  }

  static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
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
    table.dataSource = coordinator
    table.delegate = coordinator
    table.setAccessibilityLabel("Events, newest first")
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let table = scroll.documentView as? NSTableView else { return }
    context.coordinator.update(table, to: rows)
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

    /// Applies a new window of rows (oldest first) as row removals at the
    /// bottom (the oldest left the window) and insertions at the top (the
    /// newest arrived), so the table keeps the selected event selected and,
    /// when the user has scrolled down, keeps the same events in view. Falls
    /// back to a reload, still restoring the selection by event id, when the
    /// new window is not a trim-and-append of the old one.
    func update(_ table: NSTableView, to newRows: [EventRow]) {
      let old = rows
      guard !old.isEmpty, let firstNew = newRows.first,
        let keptFrom = old.firstIndex(where: { $0.id == firstNew.id }),
        old.count - keptFrom <= newRows.count,
        zip(old[keptFrom...], newRows).allSatisfy({ $0.id == $1.id })
      else {
        reload(table, to: newRows)
        return
      }
      let trimmed = keptFrom
      let appended = newRows.count - (old.count - keptFrom)
      guard trimmed > 0 || appended > 0 else {
        rows = newRows
        return
      }
      let scroll = table.enclosingScrollView
      let rowStep = table.rowHeight + table.intercellSpacing.height
      let origin = scroll?.contentView.bounds.origin ?? .zero
      let inset = scroll?.contentView.contentInsets.top ?? 0
      let following = origin.y + inset <= rowStep / 2  // at the top: follow the newest
      table.beginUpdates()
      rows = newRows
      if trimmed > 0 {
        table.removeRows(at: IndexSet((old.count - trimmed)..<old.count), withAnimation: [])
      }
      if appended > 0 { table.insertRows(at: IndexSet(0..<appended), withAnimation: []) }
      table.endUpdates()
      if !following, appended > 0, let scroll {
        // Rows arrived above what the user is reading: move down with them.
        let target = NSPoint(x: origin.x, y: origin.y + CGFloat(appended) * rowStep)
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
      }
    }

    private func reload(_ table: NSTableView, to newRows: [EventRow]) {
      let selected =
        table.selectedRow >= 0 && table.selectedRow < rows.count
        ? rows[rows.count - 1 - table.selectedRow].id : nil
      rows = newRows
      table.reloadData()
      if let selected, let index = rows.lastIndex(where: { $0.id == selected }) {
        table.selectRowIndexes(
          IndexSet(integer: rows.count - 1 - index), byExtendingSelection: false)
      }
    }

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
