import Foundation
import AinkradAppKit

public enum RavenMCPServer {
    public struct Tool: Sendable {
        public let name: String
        public let operation: String
        public let summary: String
        public let schemaJSON: String
        public let destructive: Bool
        public let readOnly: Bool
    }

    private static func schema(_ properties: [(String, String, String)],
                               required: [String] = []) -> String {
        let fields = properties.map { name, type, description in
            "\"\(name)\":{\"type\":\"\(type)\",\"description\":\"\(description)\"}"
        }.joined(separator: ",")
        let requiredList = required.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"type\":\"object\",\"properties\":{\(fields)},\"required\":[\(requiredList)]}"
    }

    public static let tools: [Tool] = [
        Tool(name: "list_accounts", operation: "list_accounts",
             summary: "List configured mail accounts and their sync state.",
             schemaJSON: schema([]), destructive: false, readOnly: true),
        Tool(name: "list_labels", operation: "list_labels",
             summary: "List labels. Covers EVERY connected account unless account_id names one. "
                    + "Label ids are per-account, so each line is prefixed with the account it "
                    + "belongs to; pass a label id back only for that account's threads.",
             schemaJSON: schema([("account_id", "string",
                                  "One account. Omit to list every account's labels.")]),
             destructive: false, readOnly: true),
        Tool(name: "search_mail", operation: "search_mail",
             summary: "Search mail across EVERY connected account unless account_id names one; "
                    + "each result line states the account it came from. Supports from:, "
                    + "label:, is:unread, is:starred. By default covers the synced window only "
                    + "(last 90 days) and never touches the network. Set include_archive=true "
                    + "to also search the full mailbox of each account in scope server-side "
                    + "(Gmail search syntax, which overlaps but is not identical to the "
                    + "operators above) — that hits the network and its hits are cached "
                    + "locally afterward.",
             schemaJSON: schema([("query", "string", "Search string."),
                                 ("account_id", "string",
                                  "One account. Omit to search every connected account."),
                                 ("limit", "integer", "Max results, default 25."),
                                 ("include_archive", "boolean",
                                  "Default false. When true, also searches the full mailbox "
                                  + "via the provider, not just the synced window.")],
                                required: ["query"]),
             destructive: false, readOnly: true),
        Tool(name: "unread_summary", operation: "unread_summary",
             summary: "Unread counts broken down by sender, plus the unread threads, across "
                    + "EVERY connected account unless account_id names one. Each thread line "
                    + "states its account. The entry point for triage.",
             schemaJSON: schema([("account_id", "string",
                                  "One account. Omit to cover every connected account.")]),
             destructive: false, readOnly: true),
        Tool(name: "read_thread", operation: "read_thread",
             summary: "Full text of one thread, with quoted trailers removed. Works for a "
                    + "thread in any connected account and reports which account it belongs "
                    + "to — reply from that one.",
             schemaJSON: schema([("thread_id", "string", "Thread id.")],
                                required: ["thread_id"]),
             destructive: false, readOnly: true),
        Tool(name: "archive", operation: "archive",
             summary: "Remove threads from the inbox. Reversible. Each thread is changed in "
                    + "the account it belongs to, so ids from different accounts may be mixed.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "trash", operation: "trash",
             summary: "Move threads to Trash. Reversible from Gmail. Each thread is changed in "
                    + "the account it belongs to, so ids from different accounts may be mixed.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "set_read", operation: "set_read",
             summary: "Mark threads read or unread, each in the account it belongs to.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids."),
                                 ("read", "boolean", "True to mark read, false for unread.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "star", operation: "star",
             summary: "Star threads, each in the account it belongs to.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "label", operation: "label",
             summary: "Add and remove labels on threads, each in the account it belongs to. "
                    + "Label ids are per-account — use ids from list_labels for that thread's "
                    + "account.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids."),
                                 ("add", "array", "Label ids to add."),
                                 ("remove", "array", "Label ids to remove.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "create_draft", operation: "create_draft",
             summary: "Create a draft visible in Compose. Does NOT send. The draft is bound to "
                    + "the account that will send it: account_id if given, otherwise the "
                    + "account of thread_id, otherwise the only connected account. With "
                    + "several accounts connected and no thread_id, account_id is required.",
             schemaJSON: schema([("to", "array", "Recipient addresses."),
                                 ("cc", "array", "CC addresses."),
                                 ("subject", "string", "Subject line."),
                                 ("body", "string", "Plain-text body."),
                                 ("in_reply_to", "string", "RFC822 message id being replied to."),
                                 ("thread_id", "string", "Thread to reply within."),
                                 ("account_id", "string",
                                  "The account that will send this draft.")],
                                required: ["to"]),
             destructive: false, readOnly: false),
        Tool(name: "send_draft", operation: "send_draft",
             summary: "Send an existing draft, from the account the draft is bound to. This "
                    + "transmits mail and cannot be undone.",
             schemaJSON: schema([("draft_id", "string", "Draft id from create_draft.")],
                                required: ["draft_id"]),
             destructive: true, readOnly: false),
    ]

    /// Internal rather than private so tests can drive routing without a host.
    static func invoke(_ tool: Tool, arguments: String,
                       perform: @MainActor @Sendable (String, String) async -> AgentActionResult)
        async -> AgentActionResult {
        await perform(tool.operation, arguments)
    }

    @MainActor
    public static func make(
        appID: String,
        perform: @escaping @MainActor @Sendable (String, String) async -> AgentActionResult
    ) -> (server: MCPAppServer, failures: [String]) {
        let server = MCPAppServer(appID: appID)
        var failures: [String] = []
        for tool in tools {
            let added = server.addTool(MCPToolSpec(
                name: tool.name,
                description: tool.summary,
                schemaJSON: tool.schemaJSON,
                destructive: tool.destructive,
                readOnly: tool.readOnly,
                handler: { arguments in
                    await invoke(tool, arguments: arguments, perform: perform)
                }))
            if !added { failures.append(tool.name) }
        }
        return (server, failures)
    }
}
