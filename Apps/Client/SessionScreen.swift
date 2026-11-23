import InputModel
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

/// The floating toolbar (plan section 7), Phase 2's subset: keyboard, sticky modifiers, common
/// keys, function keys, input mode, shortcuts, stats and disconnect. The display picker and
/// quality arrive later.
private struct ControlPill: View {
    let connection: ConnectionModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if connection.state == .streaming {
                let keyboard = connection.keyboard
                Button {
                    keyboard.softwareKeyboardShown.toggle()
                } label: {
                    Image(systemName: keyboard.softwareKeyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(keyboard.softwareKeyboardShown ? "Hide keyboard" : "Show keyboard")

                Divider().frame(height: 20)
                ForEach(Self.modifiers, id: \.label) { modifier in
                    ModifierButton(label: modifier.label, name: modifier.name,
                                   sticky: keyboard.sticky.contains(modifier.bit),
                                   locked: keyboard.locked.contains(modifier.bit)) {
                        keyboard.toggle(modifier.bit)
                    }
                }

                Divider().frame(height: 20)
                key("esc", "Escape", KeyMap.Usage.escape)
                key("⇥", "Tab", KeyMap.Usage.tab)
                key("←", "Left arrow", KeyMap.Usage.leftArrow)
                key("↑", "Up arrow", KeyMap.Usage.upArrow)
                key("↓", "Down arrow", KeyMap.Usage.downArrow)
                key("→", "Right arrow", KeyMap.Usage.rightArrow)

                Menu {
                    ForEach(0..<12, id: \.self) { n in
                        Button("F\(n + 1)") { keyboard.tap(KeyMap.Usage.f1 + UInt32(n)) }
                    }
                    Divider()
                    Button("Forward Delete") { keyboard.tap(KeyMap.Usage.deleteForward) }
                    Button("Home") { keyboard.tap(KeyMap.Usage.home) }
                    Button("End") { keyboard.tap(KeyMap.Usage.end) }
                    Button("Page Up") { keyboard.tap(KeyMap.Usage.pageUp) }
                    Button("Page Down") { keyboard.tap(KeyMap.Usage.pageDown) }
                } label: {
                    Text("fn…").font(.callout.monospaced())
                }
                .accessibilityLabel("Function and navigation keys")

                Button {
                    connection.inputMode = connection.inputMode == .direct ? .trackpad : .direct
                } label: {
                    Image(systemName: connection.inputMode == .direct ? "hand.point.up.left" : "cursorarrow.rays")
                }
                .accessibilityLabel("Input mode")
                .accessibilityValue(connection.inputMode == .direct ? "Direct touch" : "Trackpad")

                Menu {
                    ForEach(Self.shortcuts, id: \.name) { shortcut in
                        Button(shortcut.name) { keyboard.chord(shortcut.modifiers, shortcut.key) }
                    }
                } label: {
                    Image(systemName: "command.square")
                }
                .accessibilityLabel("Mac shortcuts")
                Divider().frame(height: 20)
            }

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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .opacity(0.9)
    }

    private func key(_ label: String, _ name: String, _ usage: UInt32) -> some View {
        Button {
            connection.keyboard.tap(usage)
        } label: {
            Text(label).font(.callout.monospaced()).frame(minWidth: 28, minHeight: 28)
        }
        .accessibilityLabel(name)
    }

    struct Modifier {
        let label: String
        let name: String
        let bit: ModifierSet
    }

    static let modifiers = [
        Modifier(label: "⌘", name: "Command", bit: .leftCommand),
        Modifier(label: "⌥", name: "Option", bit: .leftOption),
        Modifier(label: "⌃", name: "Control", bit: .leftControl),
        Modifier(label: "⇧", name: "Shift", bit: .leftShift),
        Modifier(label: "fn", name: "Function", bit: .function),
    ]

    struct Shortcut {
        let name: String
        let modifiers: ModifierSet
        let key: UInt32
    }

    /// Plan section 7 and 9: what iPadOS keeps for itself, sent from the menu instead.
    static let shortcuts = [
        Shortcut(name: "Mission Control", modifiers: .leftControl, key: KeyMap.Usage.upArrow),
        Shortcut(name: "Spotlight", modifiers: .leftCommand, key: KeyMap.Usage.space),
        Shortcut(name: "App Switcher", modifiers: .leftCommand, key: KeyMap.Usage.tab),
        Shortcut(name: "Show or Hide the Dock", modifiers: [.leftCommand, .leftOption], key: 0x07),  // D
        Shortcut(name: "Lock Screen", modifiers: [.leftControl, .leftCommand], key: 0x14),           // Q
        Shortcut(name: "Screenshot", modifiers: [.leftCommand, .leftShift], key: 0x20),              // 3
        Shortcut(name: "Screenshot of a Selection", modifiers: [.leftCommand, .leftShift], key: 0x21), // 4
        Shortcut(name: "Force Quit", modifiers: [.leftCommand, .leftOption], key: KeyMap.Usage.escape),
    ]
}

/// A toolbar modifier: outlined when it applies to the next key, filled when locked.
private struct ModifierButton: View {
    let label: String
    let name: String
    let sticky: Bool
    let locked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.monospaced().weight(locked ? .bold : .regular))
                .frame(minWidth: 28, minHeight: 28)
                .foregroundStyle(locked ? Color.black : Color.primary)
                .background(locked ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: sticky ? 1.5 : 0))
        }
        .accessibilityLabel(name)
        .accessibilityValue(locked ? "Locked" : sticky ? "On for the next key" : "Off")
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
                Text("Connecting to \(connection.name)…").font(.headline)
            case .negotiating:
                ProgressView()
                Text("Finding a path to \(connection.name)…").font(.headline)
            case .securing:
                ProgressView()
                Text("Starting the stream…").font(.headline)
            case .recovering:
                ProgressView()
                Text("Reconnecting…").font(.headline)
            case .paused:
                Text("Paused").font(.headline)
            case .ended(let reason):
                if let message = connection.setupError ?? Self.message(reason, host: connection.name) {
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
        case .authFailed: "\(host) could not prove its identity, or no longer trusts this iPad. Pair them again."
        case .notPaired: "\(host) has not paired with this iPad. Choose Pair New Device in Farside Host's menu on the Mac, then scan the code."
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
