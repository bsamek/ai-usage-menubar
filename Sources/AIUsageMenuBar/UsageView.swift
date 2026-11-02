import AIUsageCore
import AppKit
import SwiftUI

// Avoid the newer SDK's same-named State macro; CLT builds use the property wrapper.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct UsageView: View {
    @ObservedObject var store: UsageStore
    @ViewState private var workHoursExpanded: Bool

    init(store: UsageStore, workHoursExpanded: Bool = false) {
        self.store = store
        _workHoursExpanded = ViewState(initialValue: workHoursExpanded)
    }

    var body: some View {
        // Also invalidate stale/date-sensitive content while the popover stays open.
        TimelineView(.periodic(from: .now, by: 1)) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Usage").font(.headline)
                    Text("Spent so far today · estimated USD").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = store.snapshot {
                    Text(UsageFormat.dollars(snapshot.report.totals.totalCost))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                } else {
                    Text("—").font(.title2).foregroundStyle(.secondary)
                }
            }

            forecastSection

            if let message = store.lastError {
                notice(store.snapshot == nil ? "Refresh failed.\n\(message)"
                       : "Refresh failed. Showing the last available report.\n\(message)", color: .orange)
            } else if let warnings = store.snapshot?.warnings {
                notice(warnings, color: .orange)
            }

            if let snapshot = store.snapshot {
                if store.isStale {
                    Text("Cached report from \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.orange)
                }
                if snapshot.report.agents.isEmpty {
                    Text(store.isStale ? "No recorded usage in the cached report." : "No recorded usage today.").foregroundStyle(.secondary).padding(.vertical, 12)
                } else {
                    ContentFittingScrollView(maximumHeight: workHoursExpanded ? 230 : 370) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(snapshot.report.agents) { agent in
                                agentSection(agent)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    Text("\(UsageFormat.tokens(snapshot.report.totals.totalTokens)) total tokens, including cache")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(store.isStale ? "Last success" : "Updated")
                    Text(snapshot.fetchedAt, style: .relative)
                    Text("ago")
                }
                .font(.caption).foregroundStyle(.secondary)
            } else if store.isRefreshing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading local usage…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            }

            WorkHoursEditor(store: store, isExpanded: $workHoursExpanded)

            Divider()
            HStack {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Refreshing…" : "Refresh now", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            Text("Refreshes every 30s · local estimates, not provider billing")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 440)
    }

    private var forecastSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projected today").fontWeight(.medium)
                Spacer()
                switch store.forecast {
                case .projected(let total, _):
                    Text("≈ \(UsageFormat.dollars(total))").fontWeight(.semibold).monospacedDigit()
                case .waiting, .unavailable:
                    Text("—").foregroundStyle(.secondary)
                }
            }
            switch store.forecast {
            case .projected(_, let ended):
                Text(ended ? "Workday ended · assumes no further spend today"
                           : "At today's pace · \(store.workHoursLabel)")
                    .font(.caption).foregroundStyle(.secondary)
                if store.isStale {
                    Text("Cached forecast · based on the last successful report")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .waiting(let until):
                Text("Available after \(UsageFormat.time(until, timeZone: store.timeZone)) · 30-minute warm-up")
                    .font(.caption).foregroundStyle(.secondary)
                if store.isStale {
                    Text("Waiting for a fresh report")
                        .font(.caption).foregroundStyle(.orange)
                }
            case .unavailable:
                Text(store.snapshot == nil ? "Waiting for usage data" : "Waiting for a report for today's local date and timezone")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .help("Spend so far ÷ elapsed working hours × full working day. Assumes spending stops at the workday end. Earlier or overnight usage is included and can inflate this estimate.")
    }

    private func agentSection(_ agent: AgentUsage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(agent.displayName).fontWeight(.semibold)
                Spacer()
                Text(UsageFormat.dollars(agent.totalCost)).fontWeight(.semibold).monospacedDigit()
            }
            ForEach(agent.models) { model in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.displayName).lineLimit(2).help(model.modelName)
                        Spacer(minLength: 10)
                        Text(UsageFormat.dollars(model.cost)).monospacedDigit()
                    }
                    .font(.callout)
                    Text("\(UsageFormat.tokens(model.inputTokens)) in · \(UsageFormat.tokens(model.outputTokens)) out · \(UsageFormat.tokens(model.cacheReadTokens)) cache read · \(UsageFormat.tokens(model.cacheCreationTokens)) cache write")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 12)
            }
        }
    }

    private func notice(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption).foregroundStyle(color)
            .lineLimit(5).help(message).textSelection(.enabled)
    }
}

private struct WorkHoursEditor: View {
    @ObservedObject var store: UsageStore
    @Binding var isExpanded: Bool
    @ViewState private var start = Date()
    @ViewState private var end = Date()

    private var draft: WorkHours? {
        let calendar = UsageDayContext.calendar(in: store.timeZone)
        let startParts = calendar.dateComponents([.hour, .minute], from: start)
        let endParts = calendar.dateComponents([.hour, .minute], from: end)
        return WorkHours(startMinute: (startParts.hour ?? 0) * 60 + (startParts.minute ?? 0),
                         endMinute: (endParts.hour ?? 0) * 60 + (endParts.minute ?? 0))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    DatePicker("Start", selection: $start, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $end, displayedComponents: .hourAndMinute)
                }
                .environment(\.timeZone, store.timeZone)
                .datePickerStyle(.field)
                if draft == nil {
                    Text("End must be after start on the same day.")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("Local time · applies every day").foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply") {
                        guard let hours = draft else { return }
                        store.setWorkHours(hours)
                        isExpanded = false
                    }
                    .disabled(draft == nil)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Work hours · \(store.workHoursLabel)")
        }
        .font(.caption)
        .onAppear { resetDraft() }
        .onChange(of: isExpanded) { expanded in
            if expanded { resetDraft() }
        }
        .onChange(of: store.timeZone.identifier) { _ in resetDraft() }
    }

    private func resetDraft() {
        let calendar = UsageDayContext.calendar(in: store.timeZone)
        // A stable reference day avoids nonexistent times in the DST editor.
        let reference = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15))!
        if let window = store.workHours.window(on: reference, calendar: calendar) {
            start = window.start
            end = window.end
        }
    }
}
