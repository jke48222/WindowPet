import CoreGraphics
import Foundation

/// One window as the assistant sees it. Deliberately has no title field: the
/// permission invariant in Tier1.swift is that window titles are never read,
/// and a struct with nowhere to put one keeps that true by construction.
public struct WindowSnapshot: Equatable, Sendable {
    public let app: String
    public let frame: CGRect
    public let isFrontmost: Bool
    /// Index into the display list, so a report can say which screen.
    public let display: Int

    public init(app: String, frame: CGRect, isFrontmost: Bool, display: Int) {
        self.app = app
        self.frame = frame
        self.isFrontmost = isFrontmost
        self.display = display
    }
}

/// Turns the window list into something a model can reason about and a person
/// can recognize. Rusty already stands on these windows; until now the
/// assistant half of him could not see them at all.
public enum WindowReport {

    /// Beyond this many windows the per-window detail stops earning its
    /// tokens, and the counts carry the meaning instead.
    public static let detailLimit = 14

    /// Rounded to the nearest ten points. Window geometry is never precise
    /// enough for the last digit to mean anything, and round numbers read
    /// like a person describing a screen.
    static func size(_ frame: CGRect) -> String {
        "\(Int((frame.width / 10).rounded()) * 10) by \(Int((frame.height / 10).rounded()) * 10)"
    }

    /// Which part of its display a window sits in, in words. A model asked to
    /// tidy a screen needs the arrangement, not coordinates.
    public static func position(of frame: CGRect, in display: CGRect) -> String {
        guard display.width > 0, display.height > 0 else { return "somewhere" }
        let coverage = (frame.width * frame.height) / (display.width * display.height)
        if coverage > 0.8 { return "filling the screen" }
        let midX = (frame.midX - display.minX) / display.width
        let midY = (frame.midY - display.minY) / display.height
        let horizontal = midX < 0.34 ? "left" : (midX > 0.66 ? "right" : "middle")
        // AppKit y grows upward, so a high fraction is the top of the screen.
        let vertical = midY > 0.66 ? "top" : (midY < 0.34 ? "bottom" : "middle")
        if horizontal == "middle" && vertical == "middle" { return "centered" }
        if horizontal == "middle" { return vertical }
        if vertical == "middle" { return horizontal }
        return "\(vertical) \(horizontal)"
    }

    /// The whole report, as plain sentences. This is a tool result, so it is
    /// written to be read by the model and quoted back to the user.
    public static func describe(_ windows: [WindowSnapshot], displays: [CGRect]) -> String {
        guard !windows.isEmpty else { return "No ordinary windows are open right now." }

        var order: [String] = []
        var byApp: [String: [WindowSnapshot]] = [:]
        for window in windows {
            if byApp[window.app] == nil { order.append(window.app) }
            byApp[window.app, default: []].append(window)
        }
        // Busiest app first: that is the one a tidying request is about.
        let apps = order.sorted { a, b in
            let countA = byApp[a]?.count ?? 0, countB = byApp[b]?.count ?? 0
            if countA != countB { return countA > countB }
            return a < b
        }

        let screens = displays.count == 1 ? "one display" : "\(displays.count) displays"
        var lines = ["\(windows.count) \(windows.count == 1 ? "window" : "windows") "
                     + "across \(apps.count) \(apps.count == 1 ? "app" : "apps") on \(screens)."]

        let detailed = windows.count <= detailLimit
        for app in apps {
            let group = byApp[app] ?? []
            let front = group.contains { $0.isFrontmost } ? ", frontmost" : ""
            if detailed {
                let parts = group.map { window -> String in
                    let display = displays.indices.contains(window.display)
                        ? displays[window.display] : .zero
                    let screen = displays.count > 1 ? " on display \(window.display + 1)" : ""
                    return "\(size(window.frame)) \(position(of: window.frame, in: display))\(screen)"
                }
                lines.append("\(app)\(front): \(parts.joined(separator: "; "))")
            } else {
                let largest = group.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                let biggest = largest.map { " largest \(size($0.frame))" } ?? ""
                lines.append("\(app)\(front): \(group.count) "
                             + "\(group.count == 1 ? "window" : "windows"),\(biggest)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
