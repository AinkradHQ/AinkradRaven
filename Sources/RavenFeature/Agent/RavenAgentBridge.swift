import Foundation
import AinkradAppKit

/// Publishes what the user is looking at, and a small set of gated actions,
/// so Sage can resolve "reply to this" / "open that thread" without having to
/// search for it first.
///
/// Registration is per-host (see `RavenRuntime.init`), and MUST be undone on
/// teardown — `RavenRuntime.teardown()` calls `host.context.remove` and
/// `host.actions.remove` with the tokens this returns. A bridge that
/// registers on every host load and never removes is the same leak class the
/// per-host runtime cache was fixed for.
public enum RavenAgentBridge {
    /// `nil` when nothing is selected — deliberate, so Sage sees no stale
    /// context rather than an empty/misleading snapshot.
    @MainActor
    public static func snapshot(model: RavenViewModel) -> AgentContextSnapshot? {
        guard let thread = model.selectedThread else { return nil }
        let sender = thread.messages.last?.from?.displayLabel ?? "unknown"
        return AgentContextSnapshot(
            kind: "mail",
            title: "Mail — \(thread.subject)",
            text: """
            Selected thread: \(thread.id)
            Subject: \(thread.subject)
            Last sender: \(sender)
            Messages: \(thread.messages.count), unread: \(thread.unreadCount)
            """)
    }

    /// Registers the context source and the `open_thread` action against
    /// `host`. Returns the tokens the caller must hand back to
    /// `host.context.remove` / `host.actions.remove` on teardown.
    @MainActor
    public static func register(host: HostServices, model: RavenViewModel)
        -> (context: PluginContextToken, actions: [AgentActionToken]) {
        let contextToken = host.context.register { snapshot(model: model) }
        let open = host.actions.register(actionID: "open_thread") { arguments in
            openThread(arguments: arguments, model: model)
        }
        return (contextToken, [open])
    }

    /// Decodes `{"thread_id": "..."}` and selects the thread. Never throws or
    /// crashes on bad input — this runs in-process in the host, so malformed
    /// JSON or an unknown id must come back as an error result, not a fault.
    @MainActor
    static func openThread(arguments: String, model: RavenViewModel) -> AgentActionResult {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let id = object["thread_id"] as? String else {
            return AgentActionResult(text: "open_thread requires a thread_id string.", isError: true)
        }
        model.select(id)
        guard model.selectedThread != nil else {
            return AgentActionResult(text: "No thread with that id.", isError: true)
        }
        return AgentActionResult(text: "Opened the thread.", isError: false)
    }
}
