import AinkradAppKit
import AinkradAppKitUI
import AppKit
import SwiftUI

/// Bold, italic, underline, code, lists, quote, link and clear — the same set
/// `RichBody.Kind` can express and `RichBodyHTML` will be able to emit. One
/// list, defined once: a button here that the model cannot carry would be a
/// format the recipient never sees.
struct ComposeFormatBar: View {
    let handle: ComposeEditorHandle

    /// The link sheet's typed URL. Empty until the user opens it.
    @State private var linkURLText = ""
    @State private var isEnteringLink = false

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            buttons
            // Inline rather than a dialog: the kit has no input dialog, and a
            // scrim over the composer to type one URL would hide the text the
            // link is being attached to.
            if isEnteringLink {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradTextField(text: $linkURLText, placeholder: "https://")
                    AinkradButton(title: "Add Link", style: .primary, action: addLink)
                    AinkradButton(title: "Cancel", style: .ghost) {
                        isEnteringLink = false
                        linkURLText = ""
                    }
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: AinkradSpacing.xs) {
            button("bold", "Bold (⌘B)", .toggle(.bold))
            button("italic", "Italic (⌘I)", .toggle(.italic))
            button("underline", "Underline (⌘U)", .toggle(.underline))
            button("chevron.left.forwardslash.chevron.right", "Code", .toggle(.code))
            button("list.bullet", "Bulleted list", .toggle(.bulletItem))
            button("list.number", "Numbered list", .toggle(.numberItem))
            button("text.quote", "Quote", .toggle(.blockquote))
            AinkradIconButton(systemName: "link", size: 24, tooltip: "Add link") {
                isEnteringLink.toggle()
            }
            button("eraser", "Clear formatting", .clearFormatting)
            Spacer(minLength: 0)
        }
    }

    private func button(
        _ systemName: String, _ tooltip: String,
        _ command: RichTextCommand
    ) -> some View {
        AinkradIconButton(systemName: systemName, size: 24, tooltip: tooltip) {
            guard let textView = handle.textView else { return }
            command.apply(to: textView)
        }
    }

    private func addLink() {
        defer {
            linkURLText = ""
            isEnteringLink = false
        }
        // A link whose address is not a URL is refused rather than stored as
        // one: `RichBody` carries a real `URL`, and inventing one here would
        // put a broken `href` in a sent message.
        guard let url = URL(string: linkURLText.trimmingCharacters(in: .whitespaces)),
            url.scheme != nil, let textView = handle.textView
        else { return }
        RichTextCommand.toggle(.link(url)).apply(to: textView)
    }
}
