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
    /// `nil` when nothing is selected AND no draft is open — deliberate, so
    /// Sage sees no stale context rather than an empty/misleading snapshot.
    ///
    /// The open draft is included, and takes the title, because it is the more
    /// specific answer to "what is the user looking at": if the composer is up,
    /// the thread behind it is background. Without this, "make this more formal"
    /// resolved against the message being replied TO rather than the reply being
    /// written, which is a rewrite of the wrong text with no visible sign that
    /// anything went wrong.
    @MainActor
    public static func snapshot(model: RavenViewModel,
                                publisher: ComposeDraftPublisher = .shared)
        -> AgentContextSnapshot? {
        let draft = publisher.openDraft
        guard model.selectedThread != nil || draft != nil else { return nil }
        let threadText = model.selectedThread.map { threadSection(for: $0, model: model) }
        let draftText = draft.map(draftSection)
        let title: String
        if let draft {
            let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            title = "Mail — composing \(subject.isEmpty ? "(no subject)" : subject)"
        } else {
            title = "Mail — \(model.selectedThread?.subject ?? "")"
        }
        return AgentContextSnapshot(
            kind: "mail",
            title: title,
            text: [draftText, threadText].compactMap { $0 }.joined(separator: "\n\n"))
    }

    /// The draft, rendered so an agent can act on it without another round
    /// trip: the recipient fields verbatim, the subject, and the FULL body.
    ///
    /// Truncating the body would be the one shortcut that breaks the whole
    /// feature — "shorten this" on a truncated body returns a rewrite of a
    /// fragment, and the user pastes it over their real message.
    ///
    /// Bcc is labelled as blind, in words. An agent asked to "add everyone" or
    /// to summarise the recipients must not quietly out a blind recipient in
    /// text it writes back into the message.
    @MainActor
    static func draftSection(_ draft: OutgoingMessage) -> String {
        var lines = ["Open draft (in the composer, not sent):"]
        func field(_ label: String, _ addresses: [MailAddress]) {
            guard !addresses.isEmpty else { return }
            lines.append("\(label): \(addresses.map { $0.email }.joined(separator: ", "))")
        }
        field("To", draft.to)
        field("Cc", draft.cc)
        field("Bcc (blind — never repeat these in the message body)", draft.bcc)
        lines.append("Subject: \(draft.subject)")
        if !draft.attachments.isEmpty {
            lines.append("Attachments: " + draft.attachments.map(\.filename).joined(separator: ", "))
        }
        lines.append("Body:")
        lines.append(draft.bodyText)
        return lines.joined(separator: "\n")
    }

    @MainActor
    static func threadSection(for thread: MailThread, model: RavenViewModel) -> String {
        let sender = thread.messages.last?.from?.displayLabel ?? "unknown"
        // The account is part of the context, not a detail: with several
        // mailboxes connected, "reply to this" cannot be answered from the
        // thread alone — Sage would reply from the wrong address. The address
        // is included alongside the id because that is what actually appears in
        // a From line; it falls back to the id if the account row is gone.
        let account = model.address(ofAccount: thread.accountID) ?? thread.accountID
        return """
        Selected thread: \(thread.id)
        Account: \(account) (\(thread.accountID))
        Subject: \(thread.subject)
        Last sender: \(sender)
        Messages: \(thread.messages.count), unread: \(thread.unreadCount)
        """
    }

    /// Registers the context source and the `open_thread`/`open_compose`
    /// actions against `host`. Returns the tokens the caller must hand back to
    /// `host.context.remove` / `host.actions.remove` on teardown.
    @MainActor
    public static func register(host: HostServices, model: RavenViewModel,
                                publisher: ComposeDraftPublisher = .shared)
        -> (context: PluginContextToken, actions: [AgentActionToken]) {
        let contextToken = host.context.register { snapshot(model: model, publisher: publisher) }
        let open = host.actions.register(actionID: "open_thread") { arguments in
            openThread(arguments: arguments, model: model)
        }
        let compose = host.actions.register(actionID: "open_compose") { arguments in
            openCompose(arguments: arguments, publisher: publisher)
        }
        return (contextToken, [open, compose])
    }

    /// Decodes `{"to": [...], "cc": [...], "bcc": [...], "subject": "...",
    /// "body": "..."}` and opens the composer prefilled with it.
    ///
    /// **This never sends and never queues.** It is the "here is the reply I
    /// drafted, have a look" handoff, which is why it exists alongside the MCP
    /// `create_draft` tool rather than instead of it: `create_draft` persists a
    /// draft the user has to go and find, while this puts it on screen in front
    /// of them with the cursor in it. Neither one transmits; `send_draft` is
    /// still the only tool that can, and it still passes the host's approval
    /// gate and the undo-send hold.
    ///
    /// Malformed input comes back as an error result, never a throw or a trap —
    /// this runs in-process in the host.
    @MainActor
    static func openCompose(arguments: String,
                            publisher: ComposeDraftPublisher) -> AgentActionResult {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any] else {
            return AgentActionResult(text: "open_compose requires a JSON object.", isError: true)
        }
        func addresses(_ key: String) -> [MailAddress] {
            (object[key] as? [String] ?? []).compactMap { MailAddress(rfc5322: $0) }
        }
        let draft = OutgoingMessage(
            to: addresses("to"), cc: addresses("cc"), bcc: addresses("bcc"),
            subject: object["subject"] as? String ?? "",
            bodyText: object["body"] as? String ?? "")
        guard ComposeDraftPublisher.isWorthPublishing(draft) else {
            return AgentActionResult(
                text: "open_compose needs at least a recipient, a subject or a body.",
                isError: true)
        }
        publisher.request(prefill: draft)
        return AgentActionResult(
            text: "Opened the composer with that draft. It is NOT sent — the user reviews it "
                + "and presses Send.",
            isError: false)
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
