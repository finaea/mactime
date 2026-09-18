import Foundation
import LocalAuthentication

/// The optional lock in front of MacTime's windows: Touch ID, or the login
/// password, before the app will show you anything.
///
/// What it is for: two seconds at an unlocked Mac is enough to click the menu
/// bar icon and scroll a visual replay of the last two weeks. What it is *not*
/// for: protecting the files. A process reading the data directory never opens
/// a window, so it never meets this — that is what the encryption at rest is
/// there for, and the two must not be confused in the settings copy either.
///
/// `deviceOwnerAuthentication` rather than `deviceOwnerAuthenticationWithBiometrics`
/// so the password fallback is automatic — that is what makes the setting's
/// promise of "Touch ID *or* password" true on a Mac with no Touch ID, and on
/// one whose owner has just washed their hands. It needs no entitlement.
enum AppLock {
    /// Whether there is a device-owner credential to check against at all.
    /// False on a Mac with no login password, where the policy cannot be
    /// evaluated — see `gate`'s note on what is done about that.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// The single gate both windows open through. Kept free of `Settings`,
    /// `LAContext` and AppKit so the rule it encodes is checkable without
    /// firing a real biometric prompt at whoever is running the checks.
    ///
    /// Two things it decides:
    ///
    /// - **Open-from-closed only.** `alreadyVisible` is whether any MacTime
    ///   window is on screen, not whether *this* one is: getting past the lock
    ///   admits you to the app, so moving from the window to Settings is not a
    ///   second opening. Re-prompting on focus is the friction that makes
    ///   people switch the feature off, and it also has to be app-wide, or
    ///   Settings becomes the bypass — open it, turn the lock off, open the
    ///   window.
    /// - **Only success opens.** A failure, a cancel, or a policy that can't be
    ///   evaluated at all leaves `present` uncalled. Nothing here touches
    ///   recording: this gates viewing, and a locked-out user is still being
    ///   tracked exactly as they asked to be.
    static func gate(enabled: Bool,
                     alreadyVisible: Bool,
                     authenticate: (@escaping (Bool) -> Void) -> Void,
                     present: @escaping () -> Void) {
        guard enabled, !alreadyVisible else {
            present()
            return
        }
        authenticate { authenticated in
            if authenticated { present() }
        }
    }

    /// Ask the device owner. The completion always runs, on the main queue.
    ///
    /// A fresh `LAContext` every time, deliberately: a reused one can answer
    /// from a recent success, and "ask when the app opens" then quietly becomes
    /// "ask the first time the app opens".
    ///
    /// When the policy cannot be evaluated the answer is *yes*. That reads
    /// backwards until you ask what the false case means: no login password is
    /// set on this Mac, so there is no credential to check and no lock to
    /// enforce — anyone sitting at it is already past everything. Answering no
    /// instead would shut the owner out of their own history with no way back
    /// that doesn't involve editing defaults from a terminal. Settings says so
    /// where the toggle is, rather than leaving it to be discovered.
    static func authenticate(reason: String, then: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            NSLog("MacTime: can't ask for Touch ID or a password (%@) — opening without asking",
                  error.map { "\($0)" } ?? "no device owner credential")
            DispatchQueue.main.async { then(true) }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { then(ok) }
        }
    }
}
