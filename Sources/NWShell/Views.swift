import NWCore
import SwiftUI

/// The N0 shell: paired services with honest freshness, the selected
/// service's reported status, and the bounded event list. Untrusted text is
/// always shown with `Text(verbatim:)` after `InertText` (D-016); freshness
/// labels re-evaluate on a timer, so a silent service turns stale on screen
/// without any poll returning.
public struct RootView: View {
  @Bindable var model: AppModel
  @State private var selection: ServiceID?

  public init(model: AppModel) { self.model = model }

  public var body: some View {
    NavigationSplitView {
      List(model.services, selection: $selection) { service in
        ServiceRow(service: service).tag(service.id)
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260)
      .navigationTitle("Services")
    } detail: {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(model.problems, id: \.self) { problem in
          Label {
            Text(verbatim: problem.value)
          } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
          }
          .padding(8)
        }
        if let service = model.services.first(where: { $0.id == selection })
          ?? model.services.first
        {
          ServiceStatusView(service: service)
          Divider()
        }
        switch model.configuration.eventList {
        case .table: EventTable(rows: model.events.rows)
        case .swiftUIList: EventListView(events: model.events)
        }
        Divider()
        CountersView(counters: model.counters, events: model.events)
      }
    }
  }
}

/// Re-evaluates freshness twice a second.
struct FreshnessBadge: View {
  let service: ServiceStatusModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      let freshness = service.freshness(now: context.date)
      Label {
        Text(verbatim: freshness.label)
      } icon: {
        Image(systemName: Self.symbol(freshness)).foregroundStyle(Self.color(freshness))
      }
      .accessibilityLabel(Text(verbatim: "\(service.name.value): \(freshness.label)"))
    }
  }

  static func symbol(_ freshness: Freshness) -> String {
    switch freshness {
    case .live: return "circle.fill"
    case .connecting: return "circle.dotted"
    case .stale: return "clock.badge.exclamationmark"
    case .revoked: return "lock.slash"
    }
  }

  static func color(_ freshness: Freshness) -> Color {
    switch freshness {
    case .live: return .green
    case .connecting: return .secondary
    case .stale: return .orange
    case .revoked: return .red
    }
  }
}

struct ServiceRow: View {
  let service: ServiceStatusModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: service.name.value).font(.headline)
      FreshnessBadge(service: service).font(.caption)
      Text(verbatim: service.endpoint.value).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }
}

struct ServiceStatusView: View {
  let service: ServiceStatusModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.5)) { context in
      let freshness = service.freshness(now: context.date)
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(verbatim: service.name.value).font(.title2.bold())
          Spacer()
          FreshnessBadge(service: service)
        }
        if case .stale(_, let lastGood, let reason) = freshness {
          Text(verbatim: Self.staleLine(lastGood: lastGood, reason: reason))
            .foregroundStyle(.orange)
        }
        if case .revoked = freshness {
          Text(verbatim: "The service refused the credential. Polling stopped; pair again.")
            .foregroundStyle(.red)
        }
        if let snapshot = service.snapshot {
          let verdict = snapshot.verdict.value + (freshness.isLive ? "" : " (stale)")
          Text(
            verbatim: "Service says: \(verdict)"
              + (snapshot.version.map { " · \($0.value)" } ?? "")
          )
          .foregroundStyle(.secondary)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
              ForEach(snapshot.items) { item in
                let display = item.display(freshness)
                HStack {
                  Circle().fill(Self.color(display.tone)).frame(width: 8, height: 8)
                  Text(verbatim: item.name.value).bold()
                  Text(verbatim: display.label).foregroundStyle(.secondary)
                  Spacer()
                  Text(verbatim: item.detail.value)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .accessibilityElement(children: .combine)
              }
            }
          }
          .frame(maxHeight: 160)
        } else {
          Text(verbatim: "No status received yet.").foregroundStyle(.secondary)
        }
      }
      .padding(12)
    }
  }

  static func staleLine(lastGood: Date?, reason: InertString) -> String {
    let data = lastGood.map { "Showing data from \(Freshness.clock($0))" } ?? "No data received"
    return "\(data) — \(reason.value)."
  }

  static func color(_ tone: Tone) -> Color {
    switch tone {
    case .good: return .green
    case .bad: return .red
    case .warning: return .yellow
    case .neutral: return .gray
    }
  }
}

/// The first event list, kept only to reproduce the profiling drill
/// (`NW_EVENT_LIST=swiftui-list`): with 10,000 rows replaced by each batch,
/// this `List` stalled the main thread for over a minute (perf/results/app).
/// The window uses `EventTable` instead.
struct EventListView: View {
  let events: EventListModel

  var body: some View {
    List(events.rows.reversed()) { row in
      EventRowView(row: row)
    }
    .listStyle(.plain)
    .font(.system(.body, design: .monospaced))
  }
}

struct EventRowView: View {
  let row: EventRow

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: row.time).foregroundStyle(.secondary)
      Image(systemName: Self.symbol(row)).foregroundStyle(Self.color(row.severity))
        .accessibilityLabel(Text(verbatim: row.severity.rawValue))
      Text(verbatim: row.service.rawValue).foregroundStyle(.secondary)
      Text(verbatim: row.text).lineLimit(1).truncationMode(.tail)
    }
    .padding(.vertical, 1)
    .listRowBackground(row.isGap ? Color.orange.opacity(0.15) : nil)
  }

  static func symbol(_ row: EventRow) -> String {
    if row.isGap { return "scissors" }
    switch row.severity {
    case .ok: return "checkmark.circle"
    case .info: return "info.circle"
    case .warning: return "exclamationmark.triangle"
    case .failure: return "xmark.octagon"
    case .unknown: return "questionmark.circle"
    }
  }

  static func color(_ severity: Severity) -> Color {
    switch severity {
    case .ok: return .green
    case .info: return .secondary
    case .warning: return .orange
    case .failure: return .red
    case .unknown: return .yellow
    }
  }
}

struct CountersView: View {
  let counters: IngestCounters
  let events: EventListModel

  var body: some View {
    let line =
      "showing \(events.rows.count) newest rows · \(events.trimmed) older rows left the view "
      + "(kept in the store) · store \(counters.store.retained) retained · "
      + "dropped by ingest \(counters.queue.dropped) (shown in gap rows: \(events.droppedShown)) · "
      + "duplicates refused \(counters.pump.duplicates)"
      + (counters.pump.notStored > 0
        ? " · NOT STORED \(counters.pump.notStored): \(counters.pump.storeError ?? "")" : "")
    Text(verbatim: line)
      .font(.caption)
      .foregroundStyle(counters.pump.notStored > 0 ? .red : .secondary)
      .padding(8)
  }
}
