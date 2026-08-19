import Foundation
import Testing
@testable import AkariApp

// The first-run decision, without a launch, a window or a real Keychain.
//
// ADR-009 accepted "two sets of credentials" on the condition that the first
// launch explains it. Before this existed the whole path was missing: a user
// with nothing configured got one `ui.notice` about DashScope, painted over
// five seconds later, and nothing at all about Cloudflare.

private func row(_ slot: String, _ stored: StoredCredential) -> CredentialRow {
    CredentialRow(slot: slot, envVar: SettingsStore.defaultEnvVar(slot), stored: stored)
}

private let emptyRows = [
    row(CredentialSlotID.dashscopeAPIKey, .unset),
    row(CredentialSlotID.cloudflareAccountID, .unset),
    row(CredentialSlotID.cloudflareAPIToken, .unset),
    row(CredentialSlotID.huggingFaceToken, .unset),
]

private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "akari.tests.\(name)")!
    defaults.removePersistentDomain(forName: "akari.tests.\(name)")
    return defaults
}

@Suite struct FirstRunOnboardingTests {
    @Test func aFreshMachineWithNothingConfiguredGetsTheExplanation() {
        #expect(FirstRunOnboarding.shouldPresent(defaults: scratchDefaults(), rows: emptyRows))
    }

    @Test func itHappensOnceAndNeverAgain() {
        let defaults = scratchDefaults()
        #expect(FirstRunOnboarding.shouldPresent(defaults: defaults, rows: emptyRows))
        FirstRunOnboarding.markPresented(defaults: defaults)
        // Still no credentials — the user closed the window without filling
        // anything in. That is their choice, not a reason to reopen it on every
        // launch forever.
        #expect(!FirstRunOnboarding.shouldPresent(defaults: defaults, rows: emptyRows))
    }

    @Test func oneStoredCredentialIsEnoughToStayOutOfTheWay() {
        var rows = emptyRows
        rows[0] = row(CredentialSlotID.dashscopeAPIKey, .set("sk-example"))
        #expect(!FirstRunOnboarding.shouldPresent(defaults: scratchDefaults(), rows: rows))
    }

    @Test func aLockedKeychainIsNotTreatedAsAnEmptyOne() {
        var rows = emptyRows
        rows[0] = row(CredentialSlotID.dashscopeAPIKey, .denied)
        // `.denied` is "cannot tell", not "nothing there". Someone with a full
        // Keychain that happens to be locked must not be handed a first-run
        // lecture.
        #expect(!FirstRunOnboarding.hasAnyStoredCredential(emptyRows))
        #expect(FirstRunOnboarding.hasAnyStoredCredential(rows))
    }

    @Test func aDeliberatelyClearedSlotStillCountsAsUnconfigured() {
        var rows = emptyRows
        rows[0] = row(CredentialSlotID.dashscopeAPIKey, .cleared)
        #expect(!FirstRunOnboarding.hasAnyStoredCredential(rows))
    }

    @Test func theExplanationNamesBothHalvesAndSaysOneIsNotEnough() {
        let text = FirstRunOnboarding.explanation
        #expect(text.contains("DashScope"))
        #expect(text.contains("Cloudflare"))
        // The one sentence ADR-009 actually asked for.
        #expect(text.contains("配好一个不代表另一个能用"))
        // The Workers AI permission that produces a 403 nobody can diagnose.
        #expect(text.contains("编辑"))
        // No credential, ever, in a string that ships in the binary.
        #expect(!text.lowercased().contains("sk-"))
    }

    @Test func theFlagIsAPreferenceAndNotTheEnvFile() {
        // Naming it here so a later refactor that switches to "does .env exist"
        // has to delete a test that says why that is wrong: every development
        // checkout has a `.env`, so that test silences the onboarding exactly
        // where it is being written.
        #expect(FirstRunOnboarding.defaultsKey == "akari.onboardingShown")
    }
}

// The presentation half, added after a real first launch showed the decision
// being right and the user still seeing nothing.
//
// What was measured (macOS 26, `LSUIElement`, another app frontmost): the
// settings window opened *behind* that app and stayed there, while
// `markPresented` had already been called — so the explanation was consumed
// without ever being on screen, on that launch and every launch after it.
// These tests pin the two halves of the fix that are testable without a window:
// the explanation reaches the store, and "shown" is recorded only on dismissal.
@Suite @MainActor struct FirstRunOnboardingPresentationTests {
    /// A test must not read the developer's real `.env`, even to fingerprint it.
    private final class BlindEnvReader: EnvFileReading {
        func value(forKey key: String, atPath path: String) throws -> String? { nil }
    }

    private func store() -> SettingsStore {
        SettingsStore(store: InMemoryCredentialStore(), envReader: BlindEnvReader())
    }

    @Test func theExplanationIsHandedToTheWindowAndNotJustLogged() {
        let store = store()
        #expect(store.onboarding == nil)
        store.presentOnboarding(FirstRunOnboarding.text)
        #expect(store.onboarding?.title == FirstRunOnboarding.title)
        #expect(store.onboarding?.body.contains("配好一个不代表另一个能用") == true)
    }

    @Test func shownIsRecordedOnDismissalAndNotBefore() {
        let store = store()
        var recorded = 0
        store.onOnboardingDismissed = { recorded += 1 }
        store.presentOnboarding(FirstRunOnboarding.text)
        // Still up: nothing may have been recorded yet, or an onboarding the
        // user never saw counts as one they were given.
        #expect(recorded == 0)
        store.dismissOnboarding()
        #expect(recorded == 1)
        #expect(store.onboarding == nil)
    }

    @Test func dismissingTwiceOnlyCountsOnce() {
        let store = store()
        var recorded = 0
        store.onOnboardingDismissed = { recorded += 1 }
        store.presentOnboarding(FirstRunOnboarding.text)
        store.dismissOnboarding()
        store.dismissOnboarding()
        #expect(recorded == 1)
    }

    @Test func aDismissalWithNothingUpIsNotRecorded() {
        let store = store()
        var recorded = 0
        store.onOnboardingDismissed = { recorded += 1 }
        store.dismissOnboarding()
        #expect(recorded == 0)
    }
}
