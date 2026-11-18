// What the service does with the built-in panel on each check.

import Testing
@testable import lidless

@Suite("Policy")
struct PolicyTests {
    /// A policy that has already seen one check.
    func seen(docked: Bool) -> Policy {
        var policy = Policy()
        _ = policy.next(docked: docked, brightness: docked ? 0 : 0.7)
        return policy
    }

    @Test("first check undocked with the panel lit: keep the user's level and remember it")
    func firstUndockedLit() {
        var policy = Policy()
        #expect(policy.next(docked: false, brightness: 0.7) == .remember(0.7))
    }

    @Test("first check undocked with the panel dark: an earlier run stopped while docked, so relight it")
    func firstUndockedDark() {
        var policy = Policy()
        #expect(policy.next(docked: false, brightness: 0) == .light)
    }

    @Test("an unreadable level counts as dark, so the panel is not left black")
    func unreadableIsDark() {
        var policy = Policy()
        #expect(policy.next(docked: false, brightness: nil) == .light)
    }

    @Test("first check docked: darken")
    func firstDocked() {
        var policy = Policy()
        #expect(policy.next(docked: true, brightness: 0.7) == .darken)
    }

    @Test("plugging in darkens, unplugging relights")
    func transitions() {
        var policy = seen(docked: false)
        #expect(policy.next(docked: true, brightness: 0.7) == .darken)
        #expect(policy.next(docked: false, brightness: 0) == .light)
    }

    @Test("docked and unchanged: a level set by hand, or by macOS's own rules, is not fought")
    func dockedSteady() {
        var policy = seen(docked: true)
        #expect(policy.next(docked: true, brightness: 0.4) == .nothing)
    }

    @Test("after wake while docked, darken again, keeping the level noted on docking: macOS relit the panel itself")
    func reassertDocked() {
        var policy = seen(docked: true)
        #expect(policy.next(docked: true, brightness: 0.0625, reassert: true) == .darkenAgain)
    }

    @Test("after login while docked, darken again: macOS relights the panel as the session loads")
    func reassertAfterStart() {
        var policy = Policy()
        #expect(policy.next(docked: true, brightness: 0.5) == .darken)
        _ = policy.next(docked: true, brightness: 0.5)
        #expect(policy.next(docked: true, brightness: 0.5, reassert: true) == .darkenAgain)
    }

    @Test("after wake while docked, a panel lit by hand is darkened too: to keep it lit, stop the service")
    func reassertHandLit() {
        var policy = seen(docked: true)
        _ = policy.next(docked: true, brightness: 0.7)
        #expect(policy.next(docked: true, brightness: 0.7, reassert: true) == .darkenAgain)
    }

    @Test("docking again starts dark, whatever was lit by hand during the last dock")
    func redockStartsDark() {
        var policy = seen(docked: true)
        _ = policy.next(docked: true, brightness: 0.7)
        _ = policy.next(docked: false, brightness: 0.7)
        #expect(policy.next(docked: true, brightness: 0.7) == .darken)
        #expect(policy.next(docked: true, brightness: 0.6, reassert: true) == .darkenAgain)
    }

    @Test("a reassert with the panel still dark does nothing: no write, no log line")
    func reassertAlreadyDark() {
        var policy = seen(docked: true)
        #expect(policy.next(docked: true, brightness: 0, reassert: true) == .nothing)
    }

    @Test("after wake while undocked, the panel is left alone")
    func reassertUndocked() {
        var policy = seen(docked: false)
        #expect(policy.next(docked: false, brightness: 0.7, reassert: true) == .remember(0.7))
    }

    @Test("undocked and unchanged: follow the user's level so undocking restores it")
    func undockedSteady() {
        var policy = seen(docked: false)
        #expect(policy.next(docked: false, brightness: 0.3) == .remember(0.3))
    }

    @Test("undocked and dimmed to dark by hand: nothing to remember, and not relit")
    func undockedDimmedByHand() {
        var policy = seen(docked: false)
        #expect(policy.next(docked: false, brightness: 0.02) == .nothing)
    }

    @Test("an external display asleep is still docked: display sleep is not unplugging")
    func dockingAsleep() {
        #expect(Policy.docking([(builtin: true, asleep: false), (builtin: false, asleep: true)]))
        #expect(Policy.docking([(builtin: true, asleep: false), (builtin: false, asleep: false)]))
    }

    @Test("only the built-in display online is undocked, a monitor switched off included: it goes offline")
    func dockingBuiltinOnly() {
        #expect(!Policy.docking([(builtin: true, asleep: false)]))
    }

    @Test("the state seen is recorded for the next check")
    func records() {
        var policy = Policy()
        #expect(policy.docked == nil)
        _ = policy.next(docked: true, brightness: 0.5)
        #expect(policy.docked == true)
    }
}

@Suite("Saved level")
struct SavedLevelTests {
    @Test("a saved level is restored, whitespace and all")
    func parses() {
        #expect(SavedLevel.parse("0.42\n") == 0.42)
    }

    @Test("nothing saved, garbage, or a dark level falls back, so undocking never restores black",
          arguments: [nil, "", "bright", "0", "0.05", "-1"])
    func fallsBack(text: String?) {
        #expect(SavedLevel.parse(text) == SavedLevel.fallback)
    }

    @Test("a level above full is capped")
    func caps() {
        #expect(SavedLevel.parse("1.7") == 1.0)
    }
}
