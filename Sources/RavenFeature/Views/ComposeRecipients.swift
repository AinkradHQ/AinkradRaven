import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The recipient block: From, To, and Cc/Bcc behind a disclosure.
///
/// Split out of `ComposeSurface` when Bcc arrived. Three always-visible
/// recipient rows is what made the composer feel heavy — a To row, then two
/// rows most messages leave empty, above the subject line, before the user has
/// typed a word. `AinkradDisclosureGroup` collapses the two that are usually
/// unwanted while keeping them one click away, and the group opens itself when
/// there is something in them (a loaded draft, a `create_draft` from Sage, a
/// reply-all's Cc) so a collapsed section can never hide a recipient.
struct ComposeRecipients: View {
    let runtime: RavenRuntime
    let context: ComposeContext
    @Binding var toChips: [RecipientChip]
    @Binding var ccChips: [RecipientChip]
    @Binding var bccChips: [RecipientChip]
    @Binding var selectedFromAccountID: String?
    @Binding var isExpanded: Bool
    let candidates: [RecipientSuggestions.Candidate]

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    /// How many recipients the collapsed section is hiding. Fed to
    /// `AinkradDisclosureGroup`'s `hitCount` badge, which is exactly what that
    /// parameter is for — "there is something in here you cannot see".
    private var copyCount: Int { ccChips.count + bccChips.count }

    /// Narrowing only makes sense when the recipient list was DERIVED (a
    /// reply-all), which is the case where the user did not choose it. On a new
    /// message "reply only to this person" would be a euphemism for deleting
    /// the recipients they just typed.
    private var isolate: ((RecipientChip) -> Void)? {
        guard case .reply(let mode, _) = context, mode == .replyAll else { return nil }
        return { chip in
            toChips = [chip]
            ccChips = []
            bccChips = []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
            fromRow
            RecipientChipField(label: "To", chips: $toChips, candidates: candidates,
                               onIsolate: isolate)
            AinkradDisclosureGroup(title: "Cc & Bcc", isExpanded: $isExpanded,
                                   hitCount: isExpanded ? 0 : copyCount) {
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    RecipientChipField(label: "Cc", chips: $ccChips, candidates: candidates)
                    RecipientChipField(label: "Bcc", chips: $bccChips, candidates: candidates)
                    Text("Bcc recipients get the message. The To and Cc recipients never see "
                         + "that they were included.")
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(theme.foreground.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Never leave a typed recipient behind a closed chevron. Runs on
            // appear and on any change, so a draft loaded into the composer
            // (`load`), a reply-all prefill, and a `create_draft` from Sage all
            // reveal their Cc/Bcc rather than looking like they had none.
            .onChange(of: copyCount) { _, count in
                if count > 0 { isExpanded = true }
            }
            .onAppear { if copyCount > 0 { isExpanded = true } }
        }
    }

    /// Only a NEW message has a From to choose. A reply's account is the
    /// thread's, with no override — offering a picker that `ComposeContext.stamp`
    /// would then ignore is worse than offering none.
    @ViewBuilder
    private var fromRow: some View {
        if context.thread == nil, runtime.accounts.count > 1 {
            ComposeFromPicker(runtime: runtime, selection: $selectedFromAccountID)
        } else if let thread = context.thread,
                  let address = runtime.ownAddress(for: thread.accountID) {
            ComposeFieldWrap(label: "From") {
                Text(address)
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.7))
            }
        }
    }
}
