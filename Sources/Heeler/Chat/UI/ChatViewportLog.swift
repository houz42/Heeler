import Foundation
import Observation

// SPDX-License-Identifier: Apache-2.0
//
// The blank-viewport diagnosis ring buffer (design doc: "Blank viewport
// prevention: invariants first, diagnosis before fix"). Records the FOUR
// axes — loaded record IDs, mounted ChatScreen identity/phase, scroll
// viewport/content geometry, anchor/keyboard state — as transitions,
// WITHOUT message text. Bounded and local: no permanent high-frequency
// telemetry (the ring retains nothing in Release unless the launch
// argument opts in), no network/analytic surface, nothing leaves the
// process except the explicit stdout echo below.

/// One recorded transition: a monotonically increasing tick (cheap
/// ordering without wall-clock noise), the axis that changed, and a
/// text-free payload string (IDs, counts, geometry numbers).
struct ChatViewportEvent: Sendable, Equatable, CustomStringConvertible {
    let tick: Int
    let axis: Axis
    let payload: String

    var description: String {
        "#\(tick) \(axis.rawValue): \(payload)"
    }

    enum Axis: String, Sendable {
        case records = "records"
        case mount = "mount"
        case geometry = "geometry"
        case anchor = "anchor"
    }
}

/// The bounded ring: keeps the most recent `capacity` events, drops the
/// oldest on overflow. Retention is Debug-default; Release retains only
/// when `--chat-viewport-log` opts in (a device-repro run), and then
/// echoes each event to stdout so Console.app shows the transition live.
@MainActor
final class ChatViewportLog {
    static let capacity = 256
    static let launchArgument = "--chat-viewport-log"

    @MainActor static let shared = ChatViewportLog()

    /// Debug builds always record; Release only with the launch arg.
    static let isRecording: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
        #endif
    }()

    /// The device-repro channel: print each retained event as it lands
    /// so a Console.app capture shows the failing transition in order.
    private static let echoesToStdout: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(launchArgument)
        #else
        return isRecording
        #endif
    }()

    private var events: [ChatViewportEvent] = []
    private var tick = 0

    private init() {}

    /// Appends one transition (text-free by contract: callers pass IDs,
    /// counts and geometry — never message prose). With
    /// `--chat-viewport-log-file=<path>` (Debug only) the event also
    /// appends to that file — a UITest can then read the exact anchor/
    /// geometry sequence the app drove, since the test runner captures
    /// neither stdout nor Console.
    func record(_ axis: ChatViewportEvent.Axis, _ payload: String) {
        guard Self.isRecording else { return }
        tick += 1
        let event = ChatViewportEvent(tick: tick, axis: axis, payload: payload)
        if events.count >= Self.capacity {
            events.removeFirst(events.count - Self.capacity + 1)
        }
        events.append(event)
        if Self.echoesToStdout {
            print("CHAT-VIEWPORT \(event)")
        }
        #if DEBUG
        if let path = Self.fileEchoPath {
            let line = "CHAT-VIEWPORT \(event)\n"
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    #if DEBUG
    private static let fileEchoPath: String? = {
        for argument in ProcessInfo.processInfo.arguments
        where argument.hasPrefix("--chat-viewport-log-file=") {
            return String(argument.dropFirst("--chat-viewport-log-file=".count))
        }
        return nil
    }()
    #endif

    /// A snapshot copy of the retained window.
    func snapshot() -> [ChatViewportEvent] {
        events
    }

    /// Test seam: clears history and the tick.
    func resetForTesting() {
        events = []
        tick = 0
    }
}
