import SwiftUI
import QuotaCore

/// Antigravity's primary quotas are grouped by the provider. Keep the chosen
/// group compact here; arbitrary buckets and descriptions belong in Details.
struct AntigravityCard: View {
    @ObservedObject var state: AppState
    let now: Date

    private var current: Bool {
        state.antigravity?.isCurrent(at: now, maximumAge: state.antigravityMaximumAge,
            hasConnectionError: state.antigravityError != nil) == true
    }
    private var needsConnection: Bool {
        state.antigravityIssue == .helperMissing || state.antigravityIssue == .signInRequired
    }
    private var hasAdditionalBuckets: Bool {
        guard let group = state.selectedAntigravityGroup else { return false }
        return group.buckets.count != [group.session, group.weekly].compactMap { $0 }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderIcon(provider: .antigravity, size: 22)
                Text("Antigravity").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Button(action: state.openAntigravity) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.plain).help("Open Antigravity usage help").accessibilityLabel("Open Antigravity usage help")
            }.padding(.bottom, 2)

            if let connection = state.antigravityConnection,
               connection.busy || connection.needsCode {
                AntigravityConnectionSummary(model: connection)
            } else if needsConnection {
                if let error = state.antigravityError { compactError(error) }
                Button("Connect Antigravity...", action: state.connectAntigravity)
                    .font(.system(size: 12)).controlSize(.small)
                    .disabled(state.refreshingAntigravity)
            } else if state.antigravityIssue == .profileUnavailable {
                // Connect cannot repair the private profile. Retry rechecks it
                // and still respects the saved request schedule.
                if let error = state.antigravityError { compactError(error) }
                Button("Retry", action: state.retryAntigravity)
                    .font(.system(size: 12)).controlSize(.small)
                    .disabled(state.refreshingAntigravity)
            } else {
                if let snapshot = state.antigravity, snapshot.groups.count > 1 {
                    Picker("Quota group", selection: Binding(
                        get: { state.selectedAntigravityGroup?.name },
                        set: { state.selectedAntigravityGroupName = $0 })) {
                        Text("Choose quota group").tag(Optional<String>.none)
                        ForEach(snapshot.groups) { group in
                            Text(group.name).tag(Optional(group.name))
                        }
                    }
                    .labelsHidden().controlSize(.small)
                    .accessibilityLabel("Antigravity quota group")
                }
                if !current {
                    Label("Live usage unavailable", systemImage: "wifi.exclamationmark")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
                    compactError(state.antigravityError ?? "Current usage cannot be verified.")
                    if let snapshot = state.antigravity {
                        Text("Saved reading - \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
                    }
                }
                if let group = state.selectedAntigravityGroup, let snapshot = state.antigravity {
                    if snapshot.groups.count == 1 {
                        Text(group.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            .lineLimit(1).help(group.name)
                    }
                    UsageRow(title: "5-hour window", window: group.session, color: .blue, now: now, stale: !current,
                             duration: 5 * 3600, observedAt: snapshot.observedAt, compact: true)
                    UsageRow(title: "Weekly window", window: group.weekly, color: .blue, now: now, stale: !current,
                             duration: 7 * 86400, observedAt: snapshot.observedAt, compact: true)
                    if current {
                        Text("Updated \(snapshot.observedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .help("Request started \(snapshot.observedAt.formatted(.dateTime.day().month().year().hour().minute().timeZone()))")
                    }
                    if hasAdditionalBuckets {
                        Button("View reported quotas...", action: { state.showDetails(for: .antigravity) })
                            .font(.system(size: 11)).buttonStyle(.link)
                    }
                } else if state.antigravity != nil {
                    Text("Choose the quota group to show here and in the menu bar.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let snapshot = state.antigravity, snapshot.groups.count == 1, let group = snapshot.groups.first {
                        Button("Use \(group.name)") { state.selectedAntigravityGroupName = group.name }
                            .font(.system(size: 11)).buttonStyle(.link)
                    }
                }
                if !current {
                    if let next = state.antigravityNextRequestAt, next > now {
                        Text("Retrying automatically in \(countdown(next, now: now))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Button("Retry usage", action: state.retryAntigravity).font(.system(size: 11)).buttonStyle(.link)
                    if state.antigravity != nil {
                        Button("Last saved reading...", action: { state.showDetails(for: .antigravity) })
                            .font(.system(size: 11)).buttonStyle(.link)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func compactError(_ error: String) -> some View {
        Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
    }
}

private struct AntigravityConnectionSummary: View {
    @ObservedObject var model: AntigravityConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.caption).lineLimit(2).help(model.status)
                }
            } else if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(model.status)
            }
            if model.needsCode {
                SecureField("Authorization code", text: $model.code)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { model.submitCode() }
                Button("Complete sign-in", action: model.submitCode)
                    .disabled(model.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .controlSize(.small)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).help(error)
            }
            if model.busy || model.needsCode {
                Button("Cancel", action: model.cancel).font(.caption).buttonStyle(.link)
            }
        }
    }
}

/// This view is hosted in the existing resizable Details window. It never adds
/// model limits or reset controls to another provider's presentation.
struct AntigravityDetailsView: View {
    @ObservedObject var state: AppState
    let now: Date

    private var current: Bool {
        state.antigravity?.isCurrent(at: now, maximumAge: state.antigravityMaximumAge,
            hasConnectionError: state.antigravityError != nil) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProviderIcon(provider: .antigravity, size: 24)
                Text("Antigravity usage").font(.headline)
                Spacer()
                Button("Usage help", action: state.openAntigravity).font(.caption)
            }
            if let snapshot = state.antigravity {
                Text(current ? "Reported usage" : "Saved reading")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(current ? Color.primary : .orange)
                Text("\(snapshot.observedAt.formatted(.dateTime.day().month().year().hour().minute().timeZone()))")
                    .font(.caption).foregroundStyle(.secondary)
                if !current {
                    Text("These are historical values, not current balances.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let error = state.antigravityError { Text(error).font(.caption).foregroundStyle(.orange) }
                if let description = snapshot.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                ForEach(snapshot.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.name).font(.subheadline.weight(.semibold))
                        if let description = group.description { Text(description).font(.caption).foregroundStyle(.secondary) }
                        if group.buckets.isEmpty {
                            Text("No quota buckets reported for this group.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(group.buckets) { bucket in
                            AntigravityBucketDetails(bucket: bucket, observedAt: snapshot.observedAt, now: now, historical: !current)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                Text(state.antigravityError ?? "No Antigravity reading is available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.textSelection(.enabled)
    }
}

private struct AntigravityBucketDetails: View {
    let bucket: AntigravityQuotaBucket
    let observedAt: Date
    let now: Date
    let historical: Bool

    private var title: String { bucket.name + (bucket.window.map { " - \($0)" } ?? "") }
    private var expired: Bool { !historical && bucket.resetsAt.map { $0 <= now } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if bucket.disabled {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(historical ? "Disabled at the saved reading" : "Disabled by Antigravity")
                    .font(.caption).foregroundStyle(.secondary)
            } else if bucket.usageWindow != nil {
                UsageRow(title: title, window: bucket.usageWindow, color: .blue, now: now, stale: historical,
                         duration: bucket.windowKind?.duration, observedAt: observedAt)
            } else {
                HStack {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(expired ? "Awaiting refresh" : bucket.remainingAmount.map { "\($0) remaining\(historical ? " then" : "")" } ?? "Unavailable")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                if let reset = bucket.resetsAt {
                    let when = reset.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    Text(historical ? "Reset reported for \(when)" : "Auto reset: \(when) (\(shortCountdown(reset, now: now)))")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(reset.formatted(.dateTime.day().month().year().hour().minute().timeZone()))
                }
            }
            if let description = bucket.description { Text(description).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
