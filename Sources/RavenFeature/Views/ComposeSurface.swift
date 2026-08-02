import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Compose plus the draft list. Drafts Sage (the MCP `create_draft` tool)
/// creates land in `DraftBox.shared`, the same in-memory box this view reads
/// — so a draft created by an agent conversation shows up here, and one
/// typed here is what `send_draft` would send.
public struct ComposeSurface: View {
    let runtime: RavenRuntime

    @State private var to = ""
    @State private var cc = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var editingDraftID: String?
    @State private var isSending = false
    @State private var errorMessage: String?
    /// Bumped after every draft mutation so the list re-reads `DraftBox`,
    /// which is a plain in-memory box rather than an `@Observable` type.
    @State private var draftsVersion = 0

    public init(runtime: RavenRuntime) { self.runtime = runtime }

    public var body: some View {
        HStack(alignment: .top, spacing: AinkradSpacing.md) {
            draftList
                .frame(width: 260)
            composer
                .frame(maxWidth: .infinity)
        }
        .padding(AinkradSpacing.md)
        .ainkradPanel()
    }

    // MARK: Draft list

    private var draftList: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradSectionHeader(title: "Drafts")
            let drafts = { _ = draftsVersion; return DraftBox.shared.all() }()
            if drafts.isEmpty {
                AinkradEmptyState(icon: "square.and.pencil", title: "No drafts",
                                  message: "Start a new message, or ask Sage to draft one.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(drafts, id: \.id) { entry in
                            AinkradListRow(
                                isSelected: editingDraftID == entry.id,
                                onTap: { load(entry.id, entry.message) },
                                leading: { AinkradIconGlyph(systemName: "square.and.pencil") },
                                title: entry.message.subject.isEmpty ? "(no subject)" : entry.message.subject,
                                subtitle: entry.message.to.first?.displayLabel,
                                trailing: {
                                    AinkradIconButton(systemName: "trash", tooltip: "Delete draft") {
                                        DraftBox.shared.remove(entry.id)
                                        if editingDraftID == entry.id { clear() }
                                        draftsVersion += 1
                                    }
                                })
                        }
                    }
                }
            }
        }
    }

    private func load(_ id: String, _ message: OutgoingMessage) {
        editingDraftID = id
        to = message.to.map(\.email).joined(separator: ", ")
        cc = message.cc.map(\.email).joined(separator: ", ")
        subject = message.subject
        bodyText = message.bodyText
    }

    private func clear() {
        editingDraftID = nil
        to = ""; cc = ""; subject = ""; bodyText = ""
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            AinkradTextField(text: $to, placeholder: "To")
            AinkradTextField(text: $cc, placeholder: "Cc")
            AinkradTextField(text: $subject, placeholder: "Subject")
            AinkradTextArea(text: $bodyText, placeholder: "Write your message…",
                            minHeight: 200)

            if let errorMessage {
                AinkradBanner(message: errorMessage, status: .danger,
                              onDismiss: { self.errorMessage = nil })
            }

            HStack {
                AinkradButton(title: "Save Draft", style: .secondary, action: saveDraft)
                Spacer()
                AinkradButton(title: "Send", style: .primary, icon: "paperplane",
                              isLoading: isSending, action: send)
                    .disabled(recipients.isEmpty || isSending)
            }
        }
    }

    private var recipients: [MailAddress] {
        to.split(separator: ",").compactMap { MailAddress(rfc5322: String($0)) }
    }

    private func message() -> OutgoingMessage {
        OutgoingMessage(
            to: recipients,
            cc: cc.split(separator: ",").compactMap { MailAddress(rfc5322: String($0)) },
            subject: subject,
            bodyText: bodyText)
    }

    private func saveDraft() {
        do {
            let id = try DraftBox.shared.save(message(), id: editingDraftID)
            editingDraftID = id
            draftsVersion += 1
        } catch {
            errorMessage = "Could not save draft: \(error)"
        }
    }

    private func send() {
        guard !recipients.isEmpty else { return }
        isSending = true
        let outgoing = message()
        let draftID = editingDraftID
        Task {
            do {
                try runtime.outbox.enqueue(.send(outgoing))
                await runtime.drainOutbox()
                if let draftID { DraftBox.shared.remove(draftID) }
                clear()
                draftsVersion += 1
            } catch {
                errorMessage = "Could not queue send: \(error)"
            }
            isSending = false
        }
    }
}
