import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AinkradAppKit
import AinkradAppKitUI

/// To/Cc chip field: typed text commits into a `RecipientChip` on return,
/// comma, or tab; backspace on an empty text field pops the last chip;
/// each chip carries its own remove control. A small suggestion list, ranked
/// by `RecipientSuggestions`, appears under the field while typing.
struct RecipientChipField: View {
    let label: String
    @Binding var chips: [RecipientChip]
    let candidates: [RecipientSuggestions.Candidate]

    @State private var typed = ""
    @FocusState private var isFocused: Bool

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    private var suggestions: [RecipientSuggestions.Candidate] {
        guard isFocused, !typed.isEmpty else { return [] }
        let alreadyChipped = Set(chips.compactMap { $0.address?.email.lowercased() })
        return RecipientSuggestions.match(typed, in: candidates)
            .filter { !alreadyChipped.contains($0.address.email.lowercased()) }
            .prefix(5)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            ComposeFieldWrap(label: label) {
                WrappingChips {
                    ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                        AinkradChip(label: chip.displayLabel,
                                   systemName: chip.isValid ? nil : "exclamationmark.triangle",
                                   onRemove: { chips.remove(at: index) })
                    }
                    TextField("", text: $typed)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .frame(minWidth: 80)
                        .onSubmit { commit() }
                        .onChange(of: typed) { _, newValue in
                            if newValue.hasSuffix(",") {
                                typed = String(newValue.dropLast())
                                commit()
                            }
                        }
                        .onKeyPress(.tab) {
                            guard !typed.isEmpty else { return .ignored }
                            commit()
                            return .handled
                        }
                        .onKeyPress(.delete) {
                            guard typed.isEmpty, !chips.isEmpty else { return .ignored }
                            chips.removeLast()
                            return .handled
                        }
                }
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions.indices, id: \.self) { index in
                        let candidate = suggestions[index]
                        Button {
                            chips.append(RecipientChip(raw: rfc5322(for: candidate.address)))
                            typed = ""
                        } label: {
                            Text(candidate.address.name.map { "\($0) <\(candidate.address.email)>" }
                                ?? candidate.address.email)
                                .font(AinkradFontResolver.font(.caption, typography: typo))
                                .foregroundStyle(theme.foreground.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, AinkradSpacing.sm)
                                .padding(.vertical, AinkradSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .ainkradPanel()
            }
        }
    }

    private func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    private func commit() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chips.append(RecipientChip(raw: text))
        typed = ""
    }
}

/// Minimal label + content wrapper matching the visual weight of
/// `AinkradTextField` without requiring a second, chip-aware component in
/// AinkradAppKitUI — Compose is the only caller that needs a labeled chip
/// field today.
struct ComposeFieldWrap<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        HStack(alignment: .top, spacing: AinkradSpacing.sm) {
            Text(label)
                .font(AinkradFontResolver.font(.caption, weight: .semibold, typography: typo))
                .foregroundStyle(theme.foreground.opacity(0.55))
                .frame(width: 28, alignment: .leading)
                .padding(.top, AinkradSpacing.xs)
            content()
                .padding(.horizontal, AinkradSpacing.sm)
                .padding(.vertical, AinkradSpacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Theme surface, not `Color.gray`: the field has to sit correctly on
        // whichever theme the host is running, and a fixed grey wash reads as
        // dirty on the light ones and invisible on the dark ones. Matches
        // `AinkradTextField`'s own treatment (chamfer + elevated fill + accent
        // hairline) so a chip field and a text field are visibly one family.
        .background(ChamferShape(cut: AinkradRadius.sm).fill(theme.surfaceElevated.opacity(0.45)))
        .overlay(ChamferShape(cut: AinkradRadius.sm)
            .strokeBorder(theme.accentPrimary.opacity(0.2), lineWidth: 1))
    }
}

/// A simple left-to-right wrap layout for chips + the trailing text field.
struct WrappingChips: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0; y += rowHeight + AinkradSpacing.xs; rowHeight = 0
            }
            x += size.width + AinkradSpacing.xs
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + AinkradSpacing.xs; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + AinkradSpacing.xs
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Picks files to attach.
///
/// `NSOpenPanel`, allowing multiple selection of any file type — Compose does
/// not restrict which files can be attached, matching every other mail client.
/// Reads each picked file's bytes into memory immediately (never a cache
/// directory) and derives its MIME type from the file's extension via `UTType`,
/// falling back to `application/octet-stream` for a type `UTType` cannot
/// classify.
enum ComposeAttachmentPicker {
    @MainActor static func pick() -> [OutgoingAttachment] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return [] }
        var picked: [OutgoingAttachment] = []
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            picked.append(OutgoingAttachment(filename: url.lastPathComponent,
                                             mimeType: mimeType, data: data))
        }
        return picked
    }
}

/// The attached-files chips, each removable. Renders nothing when there are
/// none, so the composer does not reserve a row for an empty state.
struct ComposeAttachmentsRow: View {
    @Binding var attachments: [OutgoingAttachment]

    var body: some View {
        if !attachments.isEmpty {
            WrappingChips {
                ForEach(attachments) { attachment in
                    AinkradChip(label: label(attachment), systemName: "paperclip",
                                onRemove: {
                                    attachments.removeAll { $0.id == attachment.id }
                                })
                }
            }
        }
    }

    private func label(_ attachment: OutgoingAttachment) -> String {
        let sizeKB = attachment.data.count / 1024
        return sizeKB > 0 ? "\(attachment.filename) (\(sizeKB) KB)" : attachment.filename
    }
}

/// The From picker, for a NEW message only.
///
/// A reply's account is the thread's own, with no override (see
/// `ComposeContext.stamp`), so this is never shown for one — offering a picker
/// whose choice `stamp` would then ignore is worse than offering none.
///
/// Every WRITABLE account. A read-only import (Apple Mail) has no transport to
/// send through, so it is never an option here at all, rather than being
/// pickable and then refused at Send. `nil` renders as "Choose account" so an
/// ambiguous send is visibly unresolved rather than looking like a default was
/// silently picked.
struct ComposeFromPicker: View {
    let runtime: RavenRuntime
    @Binding var selection: String?

    private var writableAccounts: [MailAccount] {
        runtime.accounts.filter { !runtime.isReadOnly(accountID: $0.id) }
    }

    var body: some View {
        ComposeFieldWrap(label: "From") {
            AinkradSegmentedPicker(
                items: [nil] + writableAccounts.map { Optional($0.id) },
                selection: $selection,
                label: { accountID in
                    guard let accountID else {
                        // The "no explicit pick" segment. If something already
                        // resolves unambiguously (the Inbox's own filter), say
                        // which — otherwise this is genuinely unresolved, and
                        // `ComposeSurface.send()` refuses until a real segment
                        // is picked.
                        if let resolved = runtime.composingAccountID {
                            let address = runtime.accounts.first { $0.id == resolved }?.address
                            return address ?? resolved
                        }
                        return "Choose account"
                    }
                    return runtime.accounts.first { $0.id == accountID }?.address ?? accountID
                })
        }
    }
}
