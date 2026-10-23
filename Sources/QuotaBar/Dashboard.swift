import SwiftUI
import QuotaCore

struct Dashboard: View {
    @ObservedObject var state: AppState
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "gauge.with.dots.needle.67percent").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("QuotaBar").font(.system(size: 19, weight: .semibold))
                        Text("Your AI subscriptions, at a glance").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { state.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh both subscriptions").disabled(state.refreshingCodex && state.refreshingClaude)
                }.padding(20)
                Divider()
                ScrollView {
                    VStack(spacing: 14) {
                        ProviderCard(name: "Codex", symbol: "terminal", color: .teal, snapshot: state.codex,
                                     error: state.codexError, now: context.date, staleAfter: max(600, state.interval * 120), open: state.openCodex)
                        ProviderCard(name: "Claude", symbol: "asterisk", color: .orange, snapshot: state.claude,
                                     error: state.claudeError, now: context.date, staleAfter: max(600, state.interval * 120), open: state.openClaude)
                        if state.needsClaudeConnection {
                            Button("Connect Claude…", action: state.connectClaude)
                        }
                        if let error = state.settingsError { Text(error).font(.caption).foregroundStyle(.orange) }
                    }.padding(16)
                }.frame(height: 540)
                Divider()
                HStack {
                    Text("Menu: C Codex · A Claude · 5h / week % left").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    Menu("Options") {
                        Picker("Refresh", selection: $state.interval) {
                            Text("Every 5 minutes").tag(5.0)
                            Text("Every 15 minutes").tag(15.0)
                            Text("Manual only").tag(0.0)
                        }.onChange(of: state.interval) { state.schedule() }
                        Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLogin))
                        Button("Locate Codex CLI…", action: state.chooseCodex)
                        Button("Connect Claude…", action: state.connectClaude)
                        Button("Open Claude Usage…", action: state.openClaude)
                        Divider()
                        Button("Quit QuotaBar") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                    }.fixedSize()
                }.padding(12)
            }.frame(width: 450).background(.regularMaterial)
        }
    }
}

private struct ProviderCard: View {
    let name: String
    let symbol: String
    let color: Color
    let snapshot: UsageSnapshot?
    let error: String?
    let now: Date
    let staleAfter: Double
    let open: () -> Void
    var isCurrent: Bool { snapshot?.isCurrent(at: now, maximumAge: staleAfter, hasConnectionError: error != nil) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(color)
                Text(name).font(.system(size: 17, weight: .semibold))
                if let plan = snapshot?.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
                if isCurrent { Text("Live").font(.caption).foregroundStyle(color) }
                Spacer()
                Button(action: open) { Text("Usage ↗") }.font(.caption)
            }
            if isCurrent, let snapshot {
                windows(snapshot, historical: false)
                Text("Fetched \(sampleTime(snapshot))").font(.system(size: 10)).foregroundStyle(.secondary)
                details(snapshot, historical: false)
            } else {
                Label("Live usage unavailable", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
                Text("Current 5-hour and weekly usage cannot be verified.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                if let snapshot {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Historical values from \(sampleTime(snapshot)). These are not current balances.")
                                .font(.caption).foregroundStyle(.orange)
                            if let source = snapshot.sourceName { Text(source).font(.caption).foregroundStyle(.secondary) }
                            windows(snapshot, historical: true)
                            details(snapshot, historical: true)
                        }.padding(.top, 10)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Last saved reading").font(.system(size: 12, weight: .medium))
                            Text("\(sampleTime(snapshot)) · \(readingAge(snapshot)) ago")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
    }
    private func sampleTime(_ snapshot: UsageSnapshot) -> String {
        "\(snapshot.observedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute())) \(TimeZone.current.abbreviation(for: snapshot.observedAt) ?? "")"
    }
    private func readingAge(_ snapshot: UsageSnapshot) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(snapshot.observedAt) / 60))
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
    @ViewBuilder private func windows(_ snapshot: UsageSnapshot, historical: Bool) -> some View {
        UsageRow(title: "5-hour window", window: snapshot.session, color: color, now: now, stale: historical)
        UsageRow(title: "Weekly window", window: snapshot.weekly, color: color, now: now, stale: historical)
    }
    @ViewBuilder private func details(_ snapshot: UsageSnapshot, historical: Bool) -> some View {
        if !snapshot.additionalWindows.isEmpty {
            DisclosureGroup("Additional plan limits") {
                ForEach(snapshot.additionalWindows) { item in
                    UsageRow(title: item.title, window: item.window, color: color, now: now, stale: historical)
                }
            }.font(.caption)
        }
        if let extra = snapshot.extraUsage { extraUsage(extra) }
        if name != "Claude" || snapshot.showsResetCredits { resets }
    }
    @ViewBuilder private var resets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(color)
                Text(isCurrent ? "Available resets" : "Resets reported then").font(.system(size: 12, weight: .semibold))
                Spacer()
                if let count = snapshot?.resetCount { Text("\(count)").font(.system(size: 12, weight: .bold)).monospacedDigit() }
            }
            if let snapshot {
                if !snapshot.offers.isEmpty {
                    ForEach(snapshot.offers) { offer in offerRow(offer) }
                    let detailedCount = snapshot.offers.reduce(0) { sum, offer in
                        let (value, overflow) = sum.addingReportingOverflow(offer.remainingCount ?? 0)
                        return overflow ? Int.max : value
                    }
                    if let count = snapshot.resetCount, count > detailedCount {
                        Text("\(count - detailedCount) more · expiry details unavailable").font(.caption).foregroundStyle(.secondary)
                    }
                } else if snapshot.resetCount == 0 {
                    Text("No resets available").font(.caption).foregroundStyle(.secondary)
                } else if let count = snapshot.resetCount {
                    Text("\(count) available · expiry details not reported").font(.caption).foregroundStyle(.secondary)
                }
                if let note = snapshot.resetNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if let cooldown = snapshot.cooldownUntil, cooldown > now {
                    Text("Reset cooldown ends in \(countdown(cooldown, now: now)) · \(cooldown.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Connect to see reset offers and their expiry dates.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func expiryText(_ expiry: Date) -> String {
        let date = expiry.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "\(expiry <= now ? "Expired" : "Expires") \(date) \(TimeZone.current.abbreviation(for: expiry) ?? "")"
    }
    private func offerRow(_ offer: ResetOffer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(offer.title).font(.system(size: 12, weight: .medium))
            if name == "Claude" {
                HStack {
                    if let count = offer.remainingCount { Text("\(count) remaining\(offer.kind.map { " · \($0.capitalized)" } ?? "")") }
                    if offer.isNext { Text("Next to be used").foregroundStyle(.orange) }
                }
                if let starts = offer.startsAt, starts > now { Text("Available from \(starts.formatted(.dateTime.day().month().hour().minute()))").foregroundStyle(.secondary) }
                if offer.usableNow == false { Text(offer.unavailableReason ?? "Not usable right now").foregroundStyle(.secondary) }
            }
            if let expiry = offer.expiresAt {
                Text(expiryText(expiry)).foregroundStyle(expiry.timeIntervalSince(now) < 86400 ? Color.orange : Color.secondary)
                if expiry > now { Text("\(countdown(expiry, now: now)) left to use").foregroundStyle(.secondary) }
            } else if let expiryText = offer.expiryText {
                Text(expiryText).foregroundStyle(.secondary)
            } else { Text("Expiry not reported").foregroundStyle(.secondary) }
            if let detail = offer.detail { Text(detail).foregroundStyle(.secondary) }
        }.font(.caption).textSelection(.enabled)
    }
    private func extraUsage(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra usage\(extra.enabled.map { $0 ? " · enabled" : " · disabled" } ?? "")").fontWeight(.medium)
            if let used = extra.used {
                Text("Used: \(used.formatted(.number.precision(.fractionLength(2)))) \(extra.currency?.uppercased() ?? "(currency not reported)")")
            }
            if let limit = extra.monthlyLimit {
                Text("Monthly limit: \(limit.formatted(.number.precision(.fractionLength(2)))) \(extra.currency?.uppercased() ?? "")")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    let color: Color
    let now: Date
    let stale: Bool
    var pending: Bool { window?.awaitingReset(at: now) == true }
    var visibleWindow: UsageWindow? { !stale && pending ? nil : window }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(visibleWindow.map { "\($0.remaining)% left\(stale ? " then" : "")" } ?? (pending ? "Awaiting refresh" : "Unavailable"))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            if let window = visibleWindow {
                Text("\(window.used.formatted(.number.precision(.fractionLength(0...1))))% used\(stale ? " then" : "")").font(.system(size: 10)).foregroundStyle(.secondary)
                ProgressView(value: Double(window.remaining), total: 100)
                    .tint(stale || pending ? .gray : window.remaining <= 15 ? .red : window.remaining <= 30 ? .orange : color)
                    .accessibilityLabel("\(title), \(window.remaining) percent remaining\(stale ? " at the saved reading time" : "")")
                if let reset = window.resetsAt {
                    Text(stale ? "Reset reported for \(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))" : "Resets in \(countdown(reset, now: now)) · \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .help(reset.formatted(.dateTime.day().month().year().hour().minute().timeZone()))
                } else { Text("Reset time not reported").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }
}

func countdown(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
    if minutes < 1 { return "less than a minute" }
    if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}
