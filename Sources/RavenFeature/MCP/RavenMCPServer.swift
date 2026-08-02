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
             summary: "List labels for an account.",
             schemaJSON: schema([("account_id", "string", "Defaults to the first account.")]),
             destructive: false, readOnly: true),
        Tool(name: "search_mail", operation: "search_mail",
             summary: "Search synced threads. Supports from:, label:, is:unread, is:starred. "
                    + "Covers the synced window only, not the full archive.",
             schemaJSON: schema([("query", "string", "Search string."),
                                 ("account_id", "string", "Defaults to the first account."),
                                 ("limit", "integer", "Max results, default 25.")],
                                required: ["query"]),
             destructive: false, readOnly: true),
        Tool(name: "unread_summary", operation: "unread_summary",
             summary: "Unread counts broken down by sender, plus the unread threads. "
                    + "The entry point for triage.",
             schemaJSON: schema([("account_id", "string", "Defaults to the first account.")]),
             destructive: false, readOnly: true),
        Tool(name: "read_thread", operation: "read_thread",
             summary: "Full text of one thread, with quoted trailers removed.",
             schemaJSON: schema([("thread_id", "string", "Thread id.")],
                                required: ["thread_id"]),
             destructive: false, readOnly: true),
        Tool(name: "archive", operation: "archive",
             summary: "Remove threads from the inbox. Reversible.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "trash", operation: "trash",
             summary: "Move threads to Trash. Reversible from Gmail.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "set_read", operation: "set_read",
             summary: "Mark threads read or unread.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids."),
                                 ("read", "boolean", "True to mark read, false for unread.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "star", operation: "star",
             summary: "Star threads.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "label", operation: "label",
             summary: "Add and remove labels on threads.",
             schemaJSON: schema([("thread_ids", "array", "Thread ids."),
                                 ("add", "array", "Label ids to add."),
                                 ("remove", "array", "Label ids to remove.")],
                                required: ["thread_ids"]),
             destructive: false, readOnly: false),
        Tool(name: "create_draft", operation: "create_draft",
             summary: "Create a draft visible in Compose. Does NOT send.",
             schemaJSON: schema([("to", "array", "Recipient addresses."),
                                 ("cc", "array", "CC addresses."),
                                 ("subject", "string", "Subject line."),
                                 ("body", "string", "Plain-text body."),
                                 ("in_reply_to", "string", "RFC822 message id being replied to."),
                                 ("thread_id", "string", "Thread to reply within.")],
                                required: ["to"]),
             destructive: false, readOnly: false),
        Tool(name: "send_draft", operation: "send_draft",
             summary: "Send an existing draft. This transmits mail and cannot be undone.",
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
