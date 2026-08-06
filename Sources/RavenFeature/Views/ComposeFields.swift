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
    /// "Reply only to this person" — replaces the whole field with the one
    /// chip. Owned by the caller because on a reply-all it also has to clear
    /// Cc/Bcc, which this field cannot see. `nil` where narrowing makes no
    /// sense (a brand-new message's To).
    var onIsolate: ((RecipientChip) -> Void)?

    @State private var typed = ""
    /// Which chip's detail popover is open, by index. One at a time — a
    /// recipient list with three popovers up is unreadable.
    @State private var detailIndex: Int?
    @FocusState private var isFocused: Bool

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ravenAppearance) private var appearance

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
                            .onTapGesture { detailIndex = index }
                            .ainkradContextMenu(menuItems(for: chip, at: index))
                            // The kit's anchored HUD popover, not the system
                            // `.popover`: a recipient's full address and how
                            // often this account has mailed them is a detail
                            // ABOUT the chip, and a chip is too small to carry
                            // it inline without wrecking the wrap layout.
                            // The index guard is not belt-and-braces: removing a
                            // chip shifts every index after it, so a stale
                            // `detailIndex` would open a popover for whichever
                            // recipient slid into that slot.
                            .ainkradPopover(isPresented: Binding(
                                get: { detailIndex == index && chips.indices.contains(index) },
                                set: { if !$0, detailIndex == index { detailIndex = nil } })) {
                                RecipientDetail(chip: chip, candidates: candidates)
                            }
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
            // **Deliberately inline, and deliberately NOT `.ainkradPopover`.**
            //
            // The kit's popover is the right control for the chip detail above
            // — one discrete, click-triggered panel. It is the wrong one here:
            // it is backed by `AinkradFloatingPanel`, a real borderless
            // `NSPanel`, and this list appears, re-filters and disappears on
            // EVERY KEYSTROKE. Creating and tearing down a window per character,
            // with dismissal wired to outside-click and to the parent window's
            // key state, is a focus hazard on the one control where losing focus
            // mid-word loses the recipient being typed.
            //
            // The inline list already has the two properties the popover would
            // have been adopted for: it is on `ravenSurface`, so it obeys the
            // user's transparency setting and adds no second blur, and it is a
            // sibling of the field so it cannot outlive it.
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
                // `ravenSurface`, not the bare `.ainkradPanel()` this was.
                // With no arguments that call takes `AinkradPanel`'s default
                // `backgroundOpacity: 0.94` — an opaque slab floating inside a
                // compose overlay whose own panel is a few percent, which is
                // the most solid thing on the screen while a recipient is being
                // typed. Same modifier every Raven pane uses, so it is glass at
                // the user's setting.
                .ravenSurface(appearance)
            }
        }
    }

    private func rfc5322(for address: MailAddress) -> String {
        guard let name = address.name, !name.isEmpty else { return address.email }
        return "\(name) <\(address.email)>"
    }

    /// The chip's right-click menu. Copy is first because it is the only
    /// non-mutating item; "reply only to this person" is offered ONLY when the
    /// caller supplied a way to narrow (a reply-all), since on a new message it
    /// would just be "delete everyone else" wearing a friendlier label.
    private func menuItems(for chip: RecipientChip, at index: Int) -> [AinkradMenuItem] {
        var items = [
            AinkradMenuItem(title: "Copy Address", systemName: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(chip.address?.email ?? chip.raw, forType: .string)
            },
        ]
        if let onIsolate, chip.isValid {
            items.append(AinkradMenuItem(title: "Reply Only To This Person",
                                         systemName: "arrowshape.turn.up.left") {
                onIsolate(chip)
            })
        }
        items.append(AinkradMenuItem(title: "Remove", systemName: "xmark",
                                     isDestructive: true) {
            guard chips.indices.contains(index) else { return }
            chips.remove(at: index)
        })
        return items
    }

    private func commit() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chips.append(RecipientChip(raw: text))
        typed = ""
    }
}

/// What a chip is actually addressing, and how well the account knows them.
///
/// Shown in an `AinkradPopover` on click. The reason this exists at all: a chip
/// shows `displayLabel`, which for a named contact is the NAME — so the address
/// mail will actually go to is invisible on exactly the chips most likely to be
/// wrong. "Ahmed" could be either of two Ahmeds.
struct RecipientDetail: View {
    let chip: RecipientChip
    let candidates: [RecipientSuggestions.Candidate]

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    private var candidate: RecipientSuggestions.Candidate? {
        guard let email = chip.address?.email.lowercased() else { return nil }
        return candidates.first { $0.address.email.lowercased() == email }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            if let name = chip.address?.name, !name.isEmpty {
                Text(name)
                    .font(AinkradFontResolver.font(.body, weight: .semibold, typography: typo))
                    .foregroundStyle(theme.foreground)
            }
            Text(chip.address?.email ?? chip.raw)
                .font(AinkradFontResolver.font(.caption, typography: typo))
                .foregroundStyle(theme.foreground.opacity(0.8))
                .textSelection(.enabled)
            if !chip.isValid {
                AinkradBanner(message: "Not a valid address", status: .danger)
            } else if let candidate {
                Text("On \(candidate.frequency) thread\(candidate.frequency == 1 ? "" : "s") "
                     + "you have loaded, most recently "
                     + MailDateLabel.short(for: candidate.mostRecent))
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.55))
            } else {
                // Said plainly rather than left blank: "you have never mailed
                // this person" is the single most useful thing to know before
                // sending, and it is what `LookalikeAddress` acts on too.
                Text("You have not mailed this address before.")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.55))
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
    }
}

/// Label + content row for the composer's fields.
///
/// The label column is now `AinkradCaptionedRow` — the kit's own fixed-width
/// caption column — rather than a hand-rolled `Text().frame(width: 28)`. That
/// 28pt column was too narrow for the words in it ("From", "Subject", "Bcc")
/// and, being a different width from every other captioned form in the host,
/// made the composer the one surface whose rows did not line up with anything.
///
/// The chamfer field chrome stays local: `AinkradCaptionedRow` supplies the
/// caption column and nothing else, which is the correct division — a caption
/// column has no opinion about whether the thing beside it is a text field, a
/// segmented picker, or a wrapping chip stack.
struct ComposeFieldWrap<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo
    @Environment(\.ravenAppearance) private var appearance

    var body: some View {
        AinkradCaptionedRow(label) {
            content()
                .padding(.horizontal, AinkradSpacing.sm)
                .padding(.vertical, AinkradSpacing.xs)
                // Without this the row's trailing `Spacer(minLength: 0)` wins
                // and the field shrink-wraps its content — a To field exactly as
                // wide as the one chip in it.
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(ComposeFieldChrome(appearance: appearance))
        }
    }
}

/// The chamfer + elevated fill + accent hairline that makes a chip field and an
/// `AinkradTextField` read as one family. Extracted so the subject/body fields
/// and the chip fields cannot drift apart.
struct ComposeFieldChrome: ViewModifier {
    let appearance: RavenAppearance

    @Environment(\.ainkradTheme) private var theme

    func body(content: Content) -> some View {
        content
        // Theme surface, not `Color.gray`: the field has to sit correctly on
        // whichever theme the host is running, and a fixed grey wash reads as
        // dirty on the light ones and invisible on the dark ones. Matches
        // `AinkradTextField`'s own treatment (chamfer + elevated fill + accent
        // hairline) so a chip field and a text field are visibly one family.
        //
        // The fill is the shared card budget, not the fixed 0.45 it was. 0.45
        // over a compose panel that itself sits on the scrim composites to
        // roughly 0.7 — a field well darker than the modal holding it, and the
        // second-most solid thing in the overlay after the suggestion popover
        // above. `cardFillOpacity(isRead: false)` is the same lift a hovered
        // inbox row and an unread message card spend, so a field reads as
        // raised without being a slab.
        .background(ChamferShape(cut: AinkradRadius.sm)
            .fill(theme.surfaceElevated.opacity(appearance.cardFillOpacity(isRead: false))))
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
