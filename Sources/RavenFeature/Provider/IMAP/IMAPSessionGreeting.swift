import Foundation

/// The one server line that is not a response to anything: the connection
/// greeting, and its one-shot resolution.
///
/// Split out of `IMAPSession.swift` to keep that file inside the repo's 500-line
/// limit once `sendIdleDone` and the IDLE continuation rule landed in it, and it
/// splits along the same kind of seam `IMAPSessionCapabilities.swift` used:
/// everything here is about a value that arrives EXACTLY ONCE, before any tag
/// exists, and it touches the transport not at all — no `send`, no `read`, so the
/// invariant that every byte written leaves through `execute` (plus IDLE's one
/// documented `DONE`) is untouched by the move.
///
/// What the split costs: two of `IMAPSession`'s members had to become internal —
/// `greetingResult` and `greetingWaiter`, each annotated at its declaration. They
/// are still actor isolated, so the concurrency guarantee is unchanged; only
/// file-level hiding inside this one module is given up.
///
/// The continuation discipline is the same as everywhere else in the session: the
/// result is recorded BEFORE the waiter is resumed, and `settleGreeting` refuses
/// to act twice, so a server that sent two greetings — or a teardown racing the
/// greeting — cannot double-resume.
extension IMAPSession {

    func waitForGreeting() async throws -> IMAPGreeting {
        if let greetingResult { return try greetingResult.get() }
        return try await withCheckedThrowingContinuation { continuation in
            // No await between the check above and here, so no result can slip
            // in unobserved.
            if let greetingResult {
                continuation.resume(with: greetingResult)
            } else {
                greetingWaiter = continuation
            }
        }
    }

    func settleGreeting(_ result: Result<IMAPGreeting, any Error>) {
        guard greetingResult == nil else { return }
        greetingResult = result
        if let waiter = greetingWaiter {
            greetingWaiter = nil
            waiter.resume(with: result)
        }
    }
}
