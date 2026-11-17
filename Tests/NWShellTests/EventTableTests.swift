import AppKit
import NWCore
import XCTest

@testable import NWShell

/// F9: a batch never moves the selection to another event or the rows the
/// user is reading.
@MainActor
final class EventTableTests: XCTestCase {
  func rows(_ range: ClosedRange<Int>) -> [EventRow] {
    range.map { n in
      var event = Event(
        service: .serviceMonitor, kind: .check, key: "k\(n)", occurredAt: Date(),
        observedAt: Date(), severity: .ok, text: "event \(n)")
      event.seq = UInt64(n)
      return EventRow(event)
    }
  }

  /// The table as the window holds it, in an offscreen window so layout runs.
  func harness() -> (EventTable.Coordinator, NSTableView, NSScrollView, NSWindow) {
    let coordinator = EventTable.Coordinator()
    let scroll = EventTable.makeScrollView(coordinator: coordinator)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = scroll
    scroll.frame = window.contentView!.bounds
    return (coordinator, scroll.documentView as! NSTableView, scroll, window)
  }

  func selectedID(_ coordinator: EventTable.Coordinator, _ table: NSTableView) -> UInt64? {
    let row = table.selectedRow
    guard row >= 0, row < coordinator.rows.count else { return nil }
    return coordinator.rows[coordinator.rows.count - 1 - row].id
  }

  func topVisibleID(
    _ coordinator: EventTable.Coordinator, _ table: NSTableView, _ scroll: NSScrollView
  )
    -> UInt64?
  {
    scroll.layoutSubtreeIfNeeded()
    let top = scroll.contentView.bounds.minY + scroll.contentView.contentInsets.top
    let row = table.row(at: NSPoint(x: 5, y: max(top, 0) + 1))
    guard row >= 0 else { return nil }
    return coordinator.rows[coordinator.rows.count - 1 - row].id
  }

  func testABatchKeepsTheSelectedEventSelected() {
    let (coordinator, table, _, window) = harness()
    _ = window
    coordinator.update(table, to: rows(1...100))
    table.selectRowIndexes(IndexSet(integer: 100 - 50), byExtendingSelection: false)
    XCTAssertEqual(selectedID(coordinator, table), 50)
    coordinator.update(table, to: rows(1...110))  // ten newer events on top
    XCTAssertEqual(selectedID(coordinator, table), 50, "the selection moved to another event")
    coordinator.update(table, to: rows(21...130))  // the oldest left the bounded window
    XCTAssertEqual(selectedID(coordinator, table), 50)
    coordinator.update(table, to: rows(60...140))  // the selected event left the window
    XCTAssertNil(selectedID(coordinator, table), "a selection is never moved to another event")
  }

  func testABatchKeepsTheRowsBeingReadInView() {
    let (coordinator, table, scroll, window) = harness()
    _ = window
    coordinator.update(table, to: rows(1...500))
    let step = table.rowHeight + table.intercellSpacing.height
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200 * step))
    scroll.reflectScrolledClipView(scroll.contentView)
    let reading = topVisibleID(coordinator, table, scroll)
    XCTAssertNotNil(reading)
    coordinator.update(table, to: rows(1...520))
    XCTAssertEqual(topVisibleID(coordinator, table, scroll), reading, "the view jumped")
  }

  func testAtTheTopTheNewestStaysInView() {
    let (coordinator, table, scroll, window) = harness()
    _ = window
    coordinator.update(table, to: rows(1...100))
    coordinator.update(table, to: rows(1...130))
    XCTAssertEqual(topVisibleID(coordinator, table, scroll), 130)
  }

  func testAnUnrelatedWindowReloadsAndStillKeepsTheSelectionByID() {
    let (coordinator, table, _, window) = harness()
    _ = window
    coordinator.update(table, to: rows(1...50))
    table.selectRowIndexes(IndexSet(integer: 50 - 40), byExtendingSelection: false)
    coordinator.update(table, to: rows(30...45) + rows(60...70))  // not a trim and append
    XCTAssertEqual(selectedID(coordinator, table), 40)
  }
}
