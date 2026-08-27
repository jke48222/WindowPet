import CoreGraphics
import Foundation

/// Deterministic RNG (SplitMix64) so behavior is seedable: the rig replays
/// decisions exactly, and "random" never means "untestable".
public struct SeededRNG {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    public mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) * (1.0 / 9007199254740992.0)
    }
}

/// The needs vector from the dossier: drifts over time, modified by observed
/// events. This — not randomness — is what makes behavior feel motivated.
public struct NeedsVector: Equatable {
    public var energy: Double      // 0 = exhausted, 1 = fully charged
    public var curiosity: Double   // builds until satisfied by exploring
    public var attention: Double   // builds until the user interacts
    public var boredom: Double     // builds while idling, cleared by variety

    public init(energy: Double = 0.9, curiosity: Double = 0.4,
                attention: Double = 0.3, boredom: Double = 0.2) {
        self.energy = energy
        self.curiosity = curiosity
        self.attention = attention
        self.boredom = boredom
    }

    public static let fresh = NeedsVector()

    mutating func clamp() {
        energy = min(max(energy, 0), 1)
        curiosity = min(max(curiosity, 0), 1)
        attention = min(max(attention, 0), 1)
        boredom = min(max(boredom, 0), 1)
    }
}

/// The behavior brain: a BT-ish mode skeleton (Sleeping / Active, with
/// Reacting handled by the physics layer), utility scoring within the active
/// mode, needs drift, and event application. Pure: feed it context, get a
/// choice.
public final class BehaviorBrain {

    public enum Activity { case idle, moving, sleeping }

    public enum Event {
        case touched              // boop or grab — attention satisfied
        case thrown               // exciting, slightly tiring
        case arrivedAtWindow(new: Bool)
        case climbed
        case travelFailed
        case knockedOff           // window closed / occluded under us
        case userReturned         // mouse woke after a long absence
        case celebrated           // a distraction app was closed
    }

    public struct Context {
        public let onFloor: Bool
        public let currentWindowID: UInt32?
        public let frontWindowID: UInt32?
        public let otherWindowIDs: [UInt32]
        /// The user is focused on one big window: only quiet behaviors.
        public let calm: Bool

        public init(onFloor: Bool, currentWindowID: UInt32?,
                    frontWindowID: UInt32?, otherWindowIDs: [UInt32],
                    calm: Bool = false) {
            self.onFloor = onFloor
            self.currentWindowID = currentWindowID
            self.frontWindowID = frontWindowID
            self.otherWindowIDs = otherWindowIDs
            self.calm = calm
        }
    }

    public enum Choice: Equatable {
        case sit(TimeInterval)
        case stroll(TimeInterval)
        case stepOff
        case travelTo(UInt32)
        case climbWall
        case sleep
        case wake
    }

    public static let sleepBelow = 0.15
    public static let wakeAbove = 0.88

    public private(set) var needs: NeedsVector
    public private(set) var sleeping = false
    private var rng: SeededRNG
    private var lastChoiceKind = ""

    public init(seed: UInt64, needs: NeedsVector = .fresh) {
        self.rng = SeededRNG(seed: seed)
        self.needs = needs
    }

    /// Test/debug hook: overwrite needs wholesale.
    public func setNeeds(_ n: NeedsVector) {
        needs = n
        needs.clamp()
    }

    // MARK: - Drift

    public func advance(dt: TimeInterval, activity: Activity) {
        switch activity {
        case .idle:
            needs.energy -= 0.0022 * dt
            needs.boredom += 0.010 * dt
            needs.curiosity += 0.006 * dt
            needs.attention += 0.005 * dt
        case .moving:
            needs.energy -= 0.014 * dt
            needs.boredom -= 0.020 * dt
            needs.curiosity += 0.004 * dt
            needs.attention += 0.005 * dt
        case .sleeping:
            needs.energy += 0.030 * dt
            needs.boredom -= 0.004 * dt
            needs.curiosity += 0.002 * dt
            needs.attention += 0.001 * dt
        }
        needs.clamp()
    }

    public func applyEvent(_ event: Event) {
        switch event {
        case .touched:
            needs.attention = 0
            needs.boredom = max(0, needs.boredom - 0.4)
            if sleeping { sleeping = false } // a boop wakes the sleeper
        case .thrown:
            needs.attention = 0
            needs.energy = max(0, needs.energy - 0.05)
            if sleeping { sleeping = false }
        case .arrivedAtWindow(let new):
            needs.curiosity = max(0, needs.curiosity - (new ? 0.55 : 0.25))
            needs.boredom = max(0, needs.boredom - 0.35)
        case .climbed:
            needs.curiosity = max(0, needs.curiosity - 0.2)
        case .travelFailed:
            needs.boredom = min(1, needs.boredom + 0.1)
        case .knockedOff:
            if sleeping { sleeping = false }
        case .userReturned:
            needs.attention = 0
            needs.boredom = max(0, needs.boredom - 0.2)
            if sleeping { sleeping = false }
        case .celebrated:
            needs.boredom = max(0, needs.boredom - 0.3)
            needs.attention = max(0, needs.attention - 0.2)
        }
        needs.clamp()
    }

    // MARK: - Decisions

    public func decide(context: Context) -> Choice {
        // Mode layer first (the BT skeleton's coarse gate).
        if sleeping {
            if needs.energy >= Self.wakeAbove {
                sleeping = false
                return .wake
            }
            return .sleep
        }
        if needs.energy <= Self.sleepBelow {
            sleeping = true
            return .sleep
        }

        // Utility scoring within the active mode.
        // Focus-calm: the user is absorbed in one maximized window — sit
        // quietly (long sits; sleep still arrives via the energy gate above).
        if context.calm {
            return .sit(5 + rng.next() * 7)
        }

        // Calmer defaults: sitting is the norm; motion is the exception a
        // need has to earn. (The first tuning was exhausting to watch.)
        var candidates: [(Choice, Double)] = []
        candidates.append((.sit(3 + rng.next() * 6), 0.38 + (1 - needs.boredom) * 0.30))
        candidates.append((.stroll(1.5 + rng.next() * 2.5),
                           (0.14 + 0.48 * needs.boredom) * (0.3 + 0.7 * needs.energy)))
        if !context.onFloor {
            candidates.append((.stepOff, 0.03 + 0.12 * needs.boredom))
        }
        if let front = context.frontWindowID, front != context.currentWindowID {
            candidates.append((.travelTo(front),
                               (0.25 * needs.curiosity + 0.45 * needs.attention + 0.15 * needs.boredom) * 0.65))
        }
        if let other = context.otherWindowIDs.first(where: { $0 != context.currentWindowID }) {
            candidates.append((.travelTo(other), 0.35 * needs.curiosity + 0.08 * needs.boredom))
        }
        if context.onFloor {
            candidates.append((.climbWall, 0.05 + 0.22 * needs.curiosity * needs.energy))
        }

        // Softmax pick — temperature keeps it varied but sensible; a small
        // penalty on repeating the previous kind fights loops.
        let temperature = 0.30
        let weights = candidates.map { choice, u -> Double in
            let repeatPenalty = kind(of: choice) == lastChoiceKind ? 0.85 : 1.0
            return exp(u * repeatPenalty / temperature)
        }
        let total = weights.reduce(0, +)
        var roll = rng.next() * total
        for (i, w) in weights.enumerated() {
            roll -= w
            if roll <= 0 {
                lastChoiceKind = kind(of: candidates[i].0)
                return candidates[i].0
            }
        }
        lastChoiceKind = "sit"
        return .sit(2)
    }

    private func kind(of c: Choice) -> String {
        switch c {
        case .sit: return "sit"
        case .stroll: return "stroll"
        case .stepOff: return "stepOff"
        case .travelTo: return "travel"
        case .climbWall: return "climb"
        case .sleep: return "sleep"
        case .wake: return "wake"
        }
    }
}
