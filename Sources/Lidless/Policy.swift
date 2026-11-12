// What to do with the built-in panel on each check, given whether an external
// display is connected now and what was seen last time. Pure, so it is tested
// without displays: Tests/lidlessTests/PolicyTests.swift.

struct Policy {
    /// At or below this level the panel counts as dark. 0 is off; the margin
    /// covers DisplayServices reporting a not-quite-zero level.
    static let darkLevel: Float = 0.05

    enum Action: Equatable {
        case nothing
        /// Note the current level, then switch the backlight off.
        case darken
        /// Restore the remembered level.
        case light
        /// Remember this level for the next undock; the panel is not touched.
        case remember(Float)
    }

    /// Whether an external display was connected at the last check; nil
    /// before the first.
    private(set) var docked: Bool?

    static func isLit(_ brightness: Float?) -> Bool {
        brightness.map { $0 > darkLevel } ?? false
    }

    /// Acts only on a *change* in docking state, so a brightness set by hand
    /// while docked is never fought. `reassert` darkens a lit panel again
    /// while docked, for after wake and after login, when macOS relights the
    /// panel itself.
    mutating func next(docked now: Bool, brightness: Float?, reassert: Bool = false) -> Action {
        defer { docked = now }
        let lit = Policy.isLit(brightness)

        // First check while undocked: keep the user's brightness, unless an
        // earlier run left the panel dark.
        if docked == nil && !now {
            return lit ? .remember(brightness!) : .light
        }
        if docked != now {
            return now ? .darken : .light
        }
        if now {
            return reassert && lit ? .darken : .nothing
        }
        // Undocked and unchanged: follow the level the user picks, so that
        // undocking later restores it.
        return lit ? .remember(brightness!) : .nothing
    }
}

/// The level to restore on undock, from the saved file's text.
enum SavedLevel {
    /// Used when nothing usable was saved: bright enough to see, not glaring.
    static let fallback: Float = 0.6

    static func parse(_ text: String?) -> Float {
        guard let text,
              let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > Policy.darkLevel
        else { return fallback }
        return min(value, 1.0)
    }
}
