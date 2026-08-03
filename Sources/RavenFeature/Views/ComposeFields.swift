import SwiftUI
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
