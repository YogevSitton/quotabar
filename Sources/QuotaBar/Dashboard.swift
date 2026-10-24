import SwiftUI
import QuotaCore

struct Dashboard: View {
    @ObservedObject var state: AppState
    let maximumSize: NSSize
    // Nil while measuring the natural content height; then the measured,
    // screen-capped height so the popup has no empty space at the bottom.
    var fixedHeight: CGFloat? = nil
    var contentWidth: CGFloat {
        min(state.installation.codex && state.installation.claude ? 700 : 380, maximumSize.width)
    }
    private var resetRowLimit: Int {
        let available = maximumSize.height - (state.settingsError == nil ? 0 : 22)
        return available >= 478 ? 2 : available >= 424 ? 1 : 0
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                HStack {
                    QuotaBarIcon(size: 24)
                    Text("QuotaBar").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    // Button padding is wider than the menu's, so a narrower icon
                    // frame keeps both header controls the same 30-point width.
                    Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 14, height: 16) }
                        .help("Quit QuotaBar").keyboardShortcut("q")
                    Menu {
                        Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: state.setLogin))
                    } label: { Image(systemName: "ellipsis").frame(width: 18, height: 16) }
                        .menuStyle(.button).menuIndicator(.hidden).fixedSize().help("More")
                }.padding(.horizontal, 16).padding(.vertical, 20)
                    .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Divider()
                    VStack(spacing: 10) {
                        // Explicit columns prevent a long offer or button from
                        // expanding the hosting view beyond the screen budget.
                        let columnWidth = max(0, (contentWidth - 34) / 2)
                        let paired = state.installation.codex && state.installation.claude
                        HStack(alignment: .top, spacing: 10) {
                            if state.installation.codex {
                                    CompactProviderCard(name: "Codex", color: .teal, snapshot: state.codex,
                                                 error: state.codexError, now: context.date, staleAfter: max(600, state.interval * 120), open: state.openCodex,
                                                 resetRowLimit: resetRowLimit, details: { state.showDetails(for: "Codex") },
                                                 resetNotice: state.redeemingCodex ? "Reset request in progress…" : state.hasCodexResetNotice ? "Reset request needs attention" : nil,
                                                 canReset: state.canUseCodexReset, useReset: state.confirmCodexReset)
                                        .frame(width: paired ? columnWidth : max(0, contentWidth - 24), alignment: .topLeading)
                            }
                            if state.installation.claude && state.hasClaudeConnectionActivity, let connection = state.claudeConnection {
                                ClaudeConnectionSummary(model: connection.model, details: state.showClaudeConnectionHelp)
                                    .frame(width: paired ? columnWidth : max(0, contentWidth - 24))
                            } else if state.installation.claude && !state.needsClaudeConnection {
                                CompactProviderCard(name: "Claude", color: .orange, snapshot: state.claude,
                                             error: state.claudeError, now: context.date, staleAfter: state.claudeMaximumAge, open: state.openClaude,
                                             resetRowLimit: resetRowLimit, details: { state.showDetails(for: "Claude") }, retry: state.retryClaude,
                                             nextRetry: state.interval > 0 ? state.claudeNextRequestAt : nil)
                                    .frame(width: paired ? columnWidth : max(0, contentWidth - 24), alignment: .topLeading)
                            } else if state.installation.claude && state.needsClaudeConnection {
                                Button(action: state.connectClaude) {
                                    HStack(spacing: 8) {
                                        ProviderIcon(name: "Claude", size: 24)
                                        Text("Connect Claude…")
                                    }
                                }.controlSize(.large)
                                    .frame(width: paired ? columnWidth : max(0, contentWidth - 24)).padding(.top, 8)
                            }
                        }
                        if !state.installation.codex && !state.installation.claude {
                            Text("Install Codex or Claude to see your usage here.")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 20)
                        }
                        if let error = state.settingsError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(1).help(error) }
                    }.padding(.horizontal, 12).padding(.vertical, 16).frame(maxHeight: fixedHeight == nil ? nil : .infinity, alignment: .top)
            }.frame(width: contentWidth, height: fixedHeight).background(.regularMaterial)
        }
    }
}

private struct CompactProviderCard: View {
    let name: String
    let color: Color
    let snapshot: UsageSnapshot?
    let error: String?
    let now: Date
    let staleAfter: TimeInterval
    let open: () -> Void
    let resetRowLimit: Int
    let details: () -> Void
    var resetNotice: String? = nil
    var canReset: ((ResetOffer) -> Bool)? = nil
    var useReset: ((ResetOffer) -> Void)? = nil
    var retry: (() -> Void)? = nil
    var nextRetry: Date? = nil
    private var current: Bool { snapshot?.isCurrent(at: now, maximumAge: staleAfter, hasConnectionError: error != nil) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderIcon(name: name, size: 22)
                Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                if let plan = snapshot?.plan { Text(plan.capitalized).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 2)
                Button(action: open) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).help("Open \(name) usage").accessibilityLabel("Open \(name) usage")
            }.padding(.bottom, 2)
            if current, let snapshot {
                UsageRow(title: "5-hour window", window: snapshot.session, color: color, now: now, stale: false, compact: true)
                UsageRow(title: "Weekly window", window: snapshot.weekly, color: color, now: now, stale: false, compact: true)
                if name != "Claude" {
                    Text("Updated \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .help(snapshot.observedAt.formatted(.dateTime.day().month().year().hour().minute().timeZone()))
                }
                if name != "Claude" || snapshot.showsResetCredits {
                    Divider()
                    Label("Available resets", systemImage: "arrow.counterclockwise.circle")
                        .foregroundStyle(color).font(.system(size: 11, weight: .semibold))
                    ForEach(Array(snapshot.offers.prefix(resetRowLimit))) { offer in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(offer.title).font(.system(size: 11, weight: .medium))
                                    .lineLimit(1).help([offer.title, offer.detail].compactMap { $0 }.joined(separator: "\n"))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if name == "Codex", offer.supportsDirectRedemption, let useReset {
                                    Button("Use reset…") { useReset(offer) }
                                        .font(.system(size: 10)).controlSize(.small)
                                        .disabled(canReset?(offer) != true)
                                }
                            }
                            Text(expiry(offer) + (offer.expiresAt.map { $0 > now ? " (\(shortCountdown($0, now: now)))" : "" } ?? ""))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).help(expiry(offer))
                        }
                    }
                    if snapshot.offers.isEmpty {
                        Text(snapshot.resetCount == 0 ? "No resets available" : "Expiry details not reported")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if snapshot.offers.count > resetRowLimit {
                        Button("View all \(snapshot.offers.count) reset offers…", action: details)
                            .font(.system(size: 10)).buttonStyle(.link)
                    }
                }
            } else {
                Label("Live usage unavailable", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                Text(error ?? "Current usage cannot be verified.").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).help(error ?? "Current usage cannot be verified.")
                if name == "Claude", let snapshot {
                    Text("Saved reading · \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    UsageRow(title: "5-hour window", window: snapshot.session, color: color, now: now, stale: true, compact: true)
                    UsageRow(title: "Weekly window", window: snapshot.weekly, color: color, now: now, stale: true, compact: true)
                }
                if let nextRetry, nextRetry > now {
                    Text("Retrying automatically in \(countdown(nextRetry, now: now))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let retry { Button("Retry usage", action: retry).font(.system(size: 11)).buttonStyle(.link) }
            }
            if let resetNotice {
                Button(resetNotice, action: details).font(.system(size: 10)).buttonStyle(.link).lineLimit(1)
            }
            if !current, snapshot != nil {
                Button("Last saved reading…", action: details).font(.system(size: 11)).buttonStyle(.link)
                    .help("View historical usage with its original sample time")
            }
        }.padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }
    private func expiry(_ offer: ResetOffer) -> String {
        let count = name == "Claude" ? offer.remainingCount.map { "\($0) left · " } ?? "" : ""
        guard let date = offer.expiresAt else { return count + (offer.expiryText ?? "Expiry not reported") }
        let prefix = date <= now ? "Expired" : "Expires"
        return "\(count)\(prefix) \(date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"
    }
}

struct CodexResetStatus: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.redeemingCodex {
                HStack { ProgressView().controlSize(.small); Text("Checking and using the selected reset…") }
            }
            if let message = state.codexResetMessage { Text(message).foregroundStyle(.secondary) }
            if let error = state.codexResetError { Text(error).foregroundStyle(.orange) }
            if let error = state.resetRecoveryError { Text(error).foregroundStyle(.orange) }
            if state.pendingCodexReset != nil && !state.redeemingCodex {
                Button("Review saved reset request…", action: state.reviewPendingCodexReset)
                    .disabled(state.refreshingCodex || state.resetRecoveryError != nil)
                Button("Check ChatGPT Usage ↗", action: state.openCodex)
            }
        }.font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}

struct ProviderCard: View {
    let name: String
    let color: Color
    let snapshot: UsageSnapshot?
    let error: String?
    let now: Date
    let staleAfter: Double
    let open: () -> Void
    var canReset: ((ResetOffer) -> Bool)? = nil
    var useReset: ((ResetOffer) -> Void)? = nil
    var isCurrent: Bool { snapshot?.isCurrent(at: now, maximumAge: staleAfter, hasConnectionError: error != nil) == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    providerHeading
                    Spacer()
                    Button(action: open) { Text("Usage ↗") }.font(.caption)
                }
                VStack(alignment: .leading, spacing: 8) {
                    providerHeading
                    Button(action: open) { Text("Usage ↗") }.font(.caption)
                }
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
    private var providerHeading: some View {
        HStack {
            ProviderIcon(name: name)
            Text(name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            if let plan = snapshot?.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
            if isCurrent { Text("Live").font(.caption).foregroundStyle(color) }
        }
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
        if name != "Claude" || snapshot.showsResetCredits { resets }
    }
    @ViewBuilder private var resets: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(color)
                Text(isCurrent ? "Available resets" : "Resets reported then").font(.system(size: 12, weight: .semibold))
                Spacer()
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
                if isCurrent && (snapshot.resetCount ?? 0) > 0 {
                    if name == "Claude" {
                        Button("Use a reset on Claude ↗", action: open)
                            .help("Open Claude Usage, then select and confirm a reset there.")
                    } else if snapshot.offers.isEmpty || snapshot.offers.contains(where: { !$0.supportsDirectRedemption }) {
                        Button("Manage resets on ChatGPT ↗", action: open)
                    }
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
                if expiry > now { Text("Expires in \(countdown(expiry, now: now))").foregroundStyle(.secondary) }
            } else if let expiryText = offer.expiryText {
                Text(expiryText).foregroundStyle(.secondary)
            } else { Text("Expiry not reported").foregroundStyle(.secondary) }
            if let detail = offer.detail { Text(detail).foregroundStyle(.secondary) }
            if name == "Codex", isCurrent, offer.supportsDirectRedemption, let useReset {
                Button("Use reset…") { useReset(offer) }
                    .disabled(canReset?(offer) != true)
                    .help("Requires a fresh account-verified reading. Review and confirm before one saved credit is used.")
                    .padding(.top, 4)
            }
        }.font(.caption).textSelection(.enabled)
    }
}

private struct UsageRow: View {
    let title: String
    let window: UsageWindow?
    let color: Color
    let now: Date
    let stale: Bool
    var compact = false
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
                if !compact {
                    Text("\(window.used.formatted(.number.precision(.fractionLength(0...1))))% used\(stale ? " then" : "")").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                UsageBar(remaining: window.remaining, color: stale || pending ? .gray : window.remaining <= 15 ? .red : window.remaining <= 30 ? .orange : color)
                    .accessibilityLabel("\(title), \(window.remaining) percent remaining\(stale ? " at the saved reading time" : "")")
                if let reset = window.resetsAt {
                    // The countdown follows the reset time to keep the popup
                    // short; the timezone stays in the tooltip.
                    let when = reset.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    Text(stale ? "Reset reported for \(when)" : "Auto reset: \(when) (\(shortCountdown(reset, now: now)))")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(stale ? .secondary : .primary)
                        .lineLimit(compact ? 1 : nil).minimumScaleFactor(0.85)
                        .help(reset.formatted(.dateTime.day().month().year().hour().minute().timeZone()))
                } else { Text("Automatic reset time not reported").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
    }
}

// An empty window draws only the track; a sliver of red would read as quota left.
private struct UsageBar: View {
    let remaining: Int
    let color: Color
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if remaining > 0 {
                    Capsule().fill(color)
                        .frame(width: max(proxy.size.height, proxy.size.width * CGFloat(min(100, remaining)) / 100))
                }
            }
        }.frame(height: 5)
    }
}

/// Countdown for use in parentheses after a time, such as "1d:1h" or "2h:59m".
func shortCountdown(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
    if minutes < 1 { return "<1m" }
    if minutes >= 1440 { return "\(minutes / 1440)d:\((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h:\(minutes % 60)m" }
    return "\(minutes)m"
}

func countdown(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(ceil(date.timeIntervalSince(now) / 60)))
    if minutes < 1 { return "less than a minute" }
    if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}
