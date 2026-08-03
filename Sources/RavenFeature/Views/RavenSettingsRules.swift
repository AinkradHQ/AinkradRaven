import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// The Rules group. Folded away behind a disclosure: most people never write
/// one, and an empty rules editor was previously taking as much vertical space
/// in Settings as the accounts it sits under.
struct RulesSettingsGroup: View {
    let runtime: RavenRuntime

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    @State private var rulesVersion = 0
    @State private var editingRule: MailRule?
    @State private var isExpanded = false

    var body: some View {
        AinkradSettingsPanel(
            title: "Rules",
            hint: "Applied only to new mail as it arrives (delta sync) — never retroactively "
                + "to mail already in the store. Ordered top to bottom; a rule can stop later "
                + "rules from also running against the same thread."
        ) {
            let ruleSet = currentRules
            AinkradDisclosureGroup(title: "Rules", isExpanded: $isExpanded,
                                   hitCount: ruleSet.rules.count) {
                VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                    rulesList(ruleSet)
                    if let editingRule {
                        RuleEditor(
                            rule: editingRule,
                            previewCount: RuleSet.previewCount(editingRule,
                                                               against: runtime.model.summaries),
                            onSave: saveRule,
                            onCancel: { self.editingRule = nil })
                    } else {
                        AinkradButton(title: "Add Rule", style: .secondary, icon: "plus") {
                            editingRule = MailRule(name: "New rule", action: .archive)
                        }
                    }
                }
            }
        }
    }

    /// Reads `rulesVersion` (bumping which triggers a fresh read here) before
    /// returning `runtime.rules` — `runtime.rules` is a plain computed property,
    /// not `@Observable` storage, so nothing re-reads it just because some other
    /// observable property changed.
    private var currentRules: RuleSet {
        _ = rulesVersion
        return runtime.rules
    }

    @ViewBuilder
    private func rulesList(_ ruleSet: RuleSet) -> some View {
        if ruleSet.rules.isEmpty {
            Text("No rules yet. A rule acts on new mail automatically as it arrives.")
                .font(AinkradFontResolver.font(.caption, typography: typo))
                .foregroundStyle(theme.foreground.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(ruleSet.rules.enumerated()), id: \.element.id) { index, rule in
                    ruleRow(rule, index: index, ruleSet: ruleSet)
                }
            }
        }
    }

    private func ruleRow(_ rule: MailRule, index: Int, ruleSet: RuleSet) -> some View {
        AinkradListRow(
            isSelected: editingRule?.id == rule.id,
            onTap: nil,
            leading: {
                AinkradIconGlyph(systemName: "line.3.horizontal.decrease.circle",
                                 filled: rule.isEnabled)
            },
            title: rule.name,
            // Says what the rule DOES, not just whether it is on — a list of
            // names told the user nothing about what they had built.
            subtitle: ruleSummary(rule),
            trailing: {
                HStack(spacing: AinkradSpacing.xs) {
                    AinkradIconButton(systemName: "arrow.up", size: 22, tooltip: "Move up") {
                        moveRule(index: index, by: -1)
                    }
                    .disabled(index == 0)
                    AinkradIconButton(systemName: "arrow.down", size: 22, tooltip: "Move down") {
                        moveRule(index: index, by: 1)
                    }
                    .disabled(index == ruleSet.rules.count - 1)
                    AinkradIconButton(systemName: "pencil", size: 22, tooltip: "Edit rule") {
                        editingRule = rule
                    }
                    AinkradIconButton(systemName: "trash", size: 22, tooltip: "Delete rule") {
                        var updated = runtime.rules
                        updated.rules.removeAll { $0.id == rule.id }
                        runtime.rules = updated
                        if editingRule?.id == rule.id { editingRule = nil }
                        rulesVersion += 1
                    }
                }
            })
    }

    private func ruleSummary(_ rule: MailRule) -> String {
        let condition = rule.conditions.first
            .map { "\($0.field.rawValue) contains “\($0.contains)”" } ?? "any new mail"
        let state = rule.isEnabled ? "" : " · disabled"
        return "\(condition) → \(actionLabel(rule.action))\(state)"
    }

    private func actionLabel(_ action: ThreadAction) -> String {
        switch action {
        case .archive: return "archive"
        case .trash: return "trash"
        case .star(let on): return on ? "star" : "unstar"
        case .setRead(let read): return read ? "mark read" : "mark unread"
        case .label: return "label"
        }
    }

    private func saveRule(_ saved: MailRule) {
        var updated = runtime.rules
        if let index = updated.rules.firstIndex(where: { $0.id == saved.id }) {
            updated.rules[index] = saved
        } else {
            updated.rules.append(saved)
        }
        runtime.rules = updated
        editingRule = nil
        rulesVersion += 1
    }

    private func moveRule(index: Int, by offset: Int) {
        var updated = runtime.rules
        let target = index + offset
        guard updated.rules.indices.contains(target) else { return }
        updated.rules.swapAt(index, target)
        runtime.rules = updated
        rulesVersion += 1
    }
}

/// Minimal add/edit form for one `MailRule`: a single condition (field +
/// text), an action, the stop-processing flag, and a live "matches N of your
/// recent threads" preview computed against the currently loaded store
/// contents — so a rule that would e.g. archive everything is legible before
/// saving. Deliberately single-condition-at-a-time in this editor (the model
/// supports an ordered list; extending the UI to add/remove several is a
/// follow-up, not required for this milestone's minimal add/edit/reorder/
/// delete bar).
struct RuleEditor: View {
    let originalRule: MailRule
    let previewCount: Int
    let onSave: (MailRule) -> Void
    let onCancel: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    @State private var name: String
    @State private var field: MailRule.ConditionField
    @State private var conditionText: String
    @State private var actionKind: RuleActionKind
    @State private var stopProcessing: Bool
    @State private var isEnabled: Bool

    /// A plain, `Hashable`-by-declaration stand-in for `ThreadAction`'s cases
    /// this editor offers — kept separate from `ThreadAction` itself so the
    /// picker never needs to compare associated-value payloads.
    private enum RuleActionKind: String, CaseIterable {
        case archive, trash, star, markRead
        var label: String {
            switch self {
            case .archive: return "Archive"
            case .trash: return "Trash"
            case .star: return "Star"
            case .markRead: return "Mark read"
            }
        }
        var action: ThreadAction {
            switch self {
            case .archive: return .archive
            case .trash: return .trash
            case .star: return .star(true)
            case .markRead: return .setRead(true)
            }
        }
        static func closest(to action: ThreadAction) -> RuleActionKind {
            switch action {
            case .archive: return .archive
            case .trash: return .trash
            case .star: return .star
            case .setRead: return .markRead
            case .label: return .archive
            }
        }
    }

    init(rule: MailRule, previewCount: Int, onSave: @escaping (MailRule) -> Void,
        onCancel: @escaping () -> Void) {
        self.originalRule = rule
        self.previewCount = previewCount
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: rule.name)
        _field = State(initialValue: rule.conditions.first?.field ?? .sender)
        _conditionText = State(initialValue: rule.conditions.first?.contains ?? "")
        _actionKind = State(initialValue: RuleActionKind.closest(to: rule.action))
        _stopProcessing = State(initialValue: rule.stopProcessing)
        _isEnabled = State(initialValue: rule.isEnabled)
    }

    var body: some View {
        AinkradSectionFrame(title: "Rule") {
            VStack(alignment: .leading, spacing: AinkradSpacing.sm) {
                AinkradFormRow(title: "Name", controlWidth: 260) {
                    AinkradTextField(text: $name, placeholder: "Rule name")
                }
                AinkradFormRow(title: "When", controlWidth: 260) {
                    AinkradSegmentedPicker(items: MailRule.ConditionField.allCases,
                                           selection: $field,
                                           label: { $0.rawValue.capitalized })
                }
                AinkradFormRow(title: "Contains", controlWidth: 260) {
                    AinkradTextField(text: $conditionText, placeholder: "text to match")
                }
                AinkradFormRow(title: "Then", controlWidth: 260) {
                    AinkradSegmentedPicker(items: RuleActionKind.allCases,
                                           selection: $actionKind,
                                           label: { $0.label })
                }
                AinkradFormRow(title: "Enabled", controlWidth: 60) {
                    AinkradToggle(isOn: $isEnabled)
                }
                AinkradFormRow(title: "Stop here",
                              help: "Later rules do not also run against a matched thread.",
                              controlWidth: 60) {
                    AinkradToggle(isOn: $stopProcessing)
                }
                Text("Matches \(previewCount) of your currently loaded thread"
                     + (previewCount == 1 ? "" : "s") + ".")
                    .font(AinkradFontResolver.font(.caption, typography: typo))
                    .foregroundStyle(theme.foreground.opacity(0.6))
                HStack {
                    AinkradButton(title: "Cancel", style: .ghost, action: onCancel)
                    Spacer()
                    AinkradButton(title: "Save", style: .primary, action: save)
                }
            }
        }
    }

    private func save() {
        var updated = originalRule
        updated.name = name
        updated.conditions = [MailRule.Condition(field: field, contains: conditionText)]
        updated.action = actionKind.action
        updated.stopProcessing = stopProcessing
        updated.isEnabled = isEnabled
        onSave(updated)
    }
}
