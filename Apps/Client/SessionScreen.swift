import SessionTransport
import SwiftUI

/// The session screen (plan section 7): the Mac full screen behind the input-capturing view
/// controller, a small control pill, the stats overlay, and connection messages.
struct SessionScreen: View {
    let connection: ConnectionModel
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            SessionInputSurface(connection: connection)
                .ignoresSafeArea()

            if connection.showsStats && connection.state == .streaming {
                StatsOverlay(connection: connection)
                    .padding(12)
                    .allowsHitTesting(false)
            }

            if connection.state != .streaming {
                StatusPanel(connection: connection, close: close)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if connection.showsToolbar || connection.state != .streaming {
                ControlPill(connection: connection, close: close)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(12)
            }
        }
        .background(.black)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
    }
}

private struct ControlPill: View {
    let connection: ConnectionModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                connection.showsStats.toggle()
            } label: {
                Image(systemName: connection.showsStats ? "chart.bar.fill" : "chart.bar")
            }
            .accessibilityLabel(connection.showsStats ? "Hide stats" : "Show stats")
            Button(role: .destructive, action: close) {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Disconnect")
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(0.8)
    }
}

/// Connecting steps and ended messages (plan section 15, end reasons).
private struct StatusPanel: View {
    let connection: ConnectionModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            switch connection.state {
            case .idle, .ringing:
                ProgressView()
                Text("Connecting to \(connection.host.name)…").font(.headline)
            case .negotiating:
                ProgressView()
                Text("Finding a path to \(connection.host.name)…").font(.headline)
            case .securing:
                ProgressView()
                Text("Starting the stream…").font(.headline)
            case .recovering:
                ProgressView()
                Text("Reconnecting…").font(.headline)
            case .paused:
                Text("Paused").font(.headline)
            case .ended(let reason):
                if let message = Self.message(reason, host: connection.host.name) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.yellow)
                    Text(message).font(.headline).multilineTextAlignment(.center)
                }
                Button("Back to Macs", action: close).buttonStyle(.borderedProminent)
            case .streaming:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 480)
    }

    static func message(_ reason: SessionEndReason, host: String) -> String? {
        switch reason {
        case .userEnded: nil
        case .hostEnded: "The session was ended from \(host)."
        case .takenOver: "Another device took control of \(host)."
        case .busy: "Another device is controlling \(host)."
        case .ringTimeout: "\(host) did not answer. It may be asleep or offline."
        case .pathTimeout: "Could not reach \(host) from this network."
        case .authFailed: "This iPad is not trusted by \(host)."
        case .versionMismatch: "Farside on this iPad and Farside Host on \(host) need the same version. Update the older one."
        case .permissionMissing: "\(host) needs Screen Recording access. Open Farside Host on the Mac to allow it."
        case .hostSleeping: "\(host) went to sleep."
        case .networkLost: "The connection to \(host) was lost."
        case .internalError: "Something went wrong."
        }
    }
}

/// The first stats overlay (plan section 16). Frame age arrives with the clock map in Phase 5.
private struct StatsOverlay: View {
    let connection: ConnectionModel

    var body: some View {
        let s = connection.stats
        VStack(alignment: .leading, spacing: 2) {
            line("Path", s.path ?? "–", s.roundTripMs.map { String(format: "%.1f ms rtt", $0) })
            line("Video", [s.codec, s.resolution].compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? "–",
                 s.bitrateMbps.map { String(format: "%.1f Mbps", $0) })
            line("Frames", String(format: "%.0f in, %.0f decoded, %d shown", s.framesReceived ?? 0, s.framesDecoded ?? 0, s.framesPresented), nil)
            line("Decode", s.decodeMs.map { String(format: "%.1f ms", $0) } ?? "–",
                 s.jitterBufferMs.map { String(format: "jitter buffer %.1f ms", $0) })
            line("Loss", String(format: "%.0f packets, %.0f freezes, %.0f dropped", s.packetsLost ?? 0, s.freezes ?? 0, s.framesDropped ?? 0), nil)
            line("Display", "\(s.replacedBeforeRefresh) replaced, \(s.skippedRefreshes) refreshes skipped", nil)
            if let first = connection.timeToFirstFrame {
                line("First frame", String(format: "%.2f s after Connect", first), nil)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.green)
        .padding(10)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func line(_ label: String, _ value: String, _ extra: String?) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.green.opacity(0.7)).frame(width: 84, alignment: .leading)
            Text(value)
            if let extra { Text(extra).foregroundStyle(.green.opacity(0.8)) }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
