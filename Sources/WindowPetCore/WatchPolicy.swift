import Foundation

/// "Tell me when the build finishes."
///
/// This is the thing a creature standing on your windows can do that a chat
/// box cannot: it is already watching. Rusty counts Accessibility events per
/// app without ever reading a title, so a window that has stopped changing is
/// a signal he already has. A watch turns that signal into a promise.
///
/// Pure policy. The registry that holds live watches lives app-side.
public enum WatchPolicy {

    /// How long an app has to stay still before it counts as finished. Long
    /// enough that a pause between compiler phases does not fire it early.
    public static let defaultQuiet: TimeInterval = 25
    /// A watch nobody cancels is a leak; this is the backstop.
    public static let defaultTimeout: TimeInterval = 3600
    /// Watching more than a few things at once is a sign of a misunderstanding
    /// rather than a plan.
    public static let maxConcurrent = 5

    public enum Outcome: Equatable, Sendable {
        /// Still going. Nothing to say yet.
        case waiting
        /// The app went quiet for long enough. This is the success case.
        case settled
        /// The app quit, which usually also means the job ended.
        case quit
        /// Nothing happened for the whole timeout window.
        case expired
    }

    public struct Watch: Equatable, Sendable {
        public let id: Int
        public let app: String
        /// What the user asked to be told, echoed back when it fires.
        public let reason: String
        public let startedAt: TimeInterval
        public let quietFor: TimeInterval
        public let timeout: TimeInterval

        public init(id: Int, app: String, reason: String, startedAt: TimeInterval,
                    quietFor: TimeInterval = WatchPolicy.defaultQuiet,
                    timeout: TimeInterval = WatchPolicy.defaultTimeout) {
            self.id = id
            self.app = app
            self.reason = reason
            self.startedAt = startedAt
            self.quietFor = quietFor
            self.timeout = timeout
        }
    }

    /// `lastActivityAt` is when that app last moved, resized, opened, closed
    /// or retitled a window. A watch never settles on its own first tick: the
    /// quiet stretch is measured from the watch's start, so asking about an
    /// app that was already idle still waits for real quiet rather than
    /// answering instantly.
    public static func evaluate(_ watch: Watch, lastActivityAt: TimeInterval,
                                appRunning: Bool, now: TimeInterval) -> Outcome {
        if !appRunning { return .quit }
        if now - watch.startedAt >= watch.timeout { return .expired }
        let sinceActivity = now - max(lastActivityAt, watch.startedAt)
        return sinceActivity >= watch.quietFor ? .settled : .waiting
    }

    /// What Rusty says out loud when a watch resolves. Nil for `.waiting`,
    /// because saying nothing is the correct output most of the time.
    public static func message(for outcome: Outcome, watch: Watch) -> String? {
        let tail = watch.reason.isEmpty ? "" : " You asked about \(watch.reason)."
        switch outcome {
        case .waiting:
            return nil
        case .settled:
            return "\(watch.app) has gone quiet.\(tail)"
        case .quit:
            return "\(watch.app) just quit.\(tail)"
        case .expired:
            return "I have been watching \(watch.app) for an hour and it never settled, so I am letting that one go.\(tail)"
        }
    }

    /// The line said back the moment a watch is set, so the promise is
    /// explicit rather than silent.
    public static func acknowledgement(_ watch: Watch) -> String {
        "Watching \(watch.app). I will say something when it goes quiet for "
            + "\(Int(watch.quietFor)) seconds, or if it quits."
    }

    public static func listing(_ watches: [Watch]) -> String {
        guard !watches.isEmpty else { return "I am not watching anything right now." }
        return "Watching: " + watches.map { watch in
            watch.reason.isEmpty ? watch.app : "\(watch.app) (\(watch.reason))"
        }.joined(separator: ", ")
    }
}
