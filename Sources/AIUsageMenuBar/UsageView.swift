import AIUsageCore
import AppKit
import SwiftUI

struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI Usage").font(.headline)
                    Text("Today · estimated USD").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = store.snapshot {
                    Text(UsageFormat.dollars(snapshot.report.totals.totalCost))
                        .font(.title2.weight(.semibold)).monospacedDigit()
                } else {
                    Text("—").font(.title2).foregroundStyle(.secondary)
                }
            }

            if let message = store.lastError {
                notice("Refresh failed. Showing the last available report.\n\(message)", color: .orange)
            } else if let warnings = store.snapshot?.warnings {
                notice(warnings, color: .orange)
            }

            if let snapshot = store.snapshot {
                if store.isStale {
                    Text("Cached report from \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.orange)
                }
                if snapshot.report.agents.isEmpty {
                    Text("No recorded usage today.").foregroundStyle(.secondary).padding(.vertical, 12)
                } else {
                    ContentFittingScrollView(maximumHeight: 370) {
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
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 4) {
                        Text(store.isStale ? "Last success" : "Updated")
                        Text(snapshot.fetchedAt, style: .relative)
                        Text("ago")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if store.isRefreshing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Reading local usage…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 16)
            }

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
