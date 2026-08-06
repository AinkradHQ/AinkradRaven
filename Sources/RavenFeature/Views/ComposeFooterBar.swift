import SwiftUI
import AinkradAppKit
import AinkradAppKitUI

/// Attach, schedule, save and send on one row, plus the schedule control.
///
/// Split out of `ComposeSurface` when the schedule presets arrived — the file
/// was already near the 500-line cap and the footer is a self-contained strip
/// with no access to the draft's content.
struct ComposeFooterBar: View {
    let canSend: Bool
    let isSending: Bool
    @Binding var isScheduling: Bool
    @Binding var scheduledSendAt: Date?
    /// Autosave state, rendered as a quiet caption rather than a component.
    let draftStateText: String?
    let onAttach: () -> Void
    let onSaveDraft: () -> Void
    let onSend: () -> Void

    @Environment(\.ainkradTheme) private var theme
    @Environment(\.ainkradTypography) private var typo

    var body: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            if isScheduling { scheduleControl }
            HStack(spacing: AinkradSpacing.xs) {
                AinkradIconButton(systemName: "paperclip", size: 26, tooltip: "Attach files…",
                                  action: onAttach)
                AinkradIconButton(systemName: "clock", size: 26,
                                  tooltip: isScheduling ? "Cancel scheduling"
                                                        : "Schedule for later") {
                    isScheduling.toggle()
                    if !isScheduling { scheduledSendAt = nil }
                }
                if let draftStateText {
                    // **`AinkradStatusBar` was considered and rejected here.**
                    // That component is a segmented METER — `value / total`
                    // filled segments. Autosave state is not a magnitude; it is
                    // one of three words ("Saving…", "Draft saved", nothing), and
                    // a twelve-segment bar that is either 0% or 100% full would
                    // be a progress indicator for something with no progress.
                    Text(draftStateText)
                        .font(AinkradFontResolver.font(.caption, typography: typo))
                        .foregroundStyle(theme.foreground.opacity(0.45))
                }
                Spacer(minLength: AinkradSpacing.xs)
                AinkradButton(title: "Save Draft", style: .ghost, action: onSaveDraft)
                AinkradButton(title: scheduledSendAt == nil ? "Send" : "Schedule Send",
                              style: .primary, icon: "paperplane",
                              isLoading: isSending, action: onSend)
                    .disabled(!canSend || isSending)
            }
        }
    }

    /// Scheduled send: the four times it is actually wanted for, plus the raw
    /// picker for everything else.
    ///
    /// The presets are not a shortcut for the picker — they are the primary
    /// control. "Tonight" through a `DatePicker` costs the user a date decision,
    /// an hour decision and a minute decision to express one word, and every
    /// one of those is a chance to schedule 8am instead of 8pm.
    ///
    /// Still made plain in the UI (not just a code comment) that this only fires
    /// while the app is running.
    private var scheduleControl: some View {
        VStack(alignment: .leading, spacing: AinkradSpacing.xs) {
            HStack(spacing: AinkradSpacing.xs) {
                ForEach(SchedulePresets.presets(now: Date())) { preset in
                    AinkradButton(title: preset.title,
                                  style: isSelected(preset.date) ? .primary : .ghost) {
                        scheduledSendAt = preset.date
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: AinkradSpacing.xs) {
                DatePicker("", selection: Binding(
                    get: { scheduledSendAt ?? Date().addingTimeInterval(3600) },
                    set: { scheduledSendAt = $0 }),
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                AinkradIconGlyph(systemName: "info.circle")
                    .ainkradTooltip("Raven must be running at the scheduled time for this to "
                                    + "send — a message scheduled while your Mac is asleep sends "
                                    + "when the app next wakes, not exactly at the time you "
                                    + "picked.")
                Spacer(minLength: 0)
            }
        }
    }

    /// Whether a preset is the current choice. Compared to the minute, not the
    /// instant: the picker below rounds to minutes, so an exact `==` against a
    /// preset's seconds-zeroed date would light up and then go dark for no
    /// visible reason.
    private func isSelected(_ date: Date) -> Bool {
        guard let scheduledSendAt else { return false }
        return abs(scheduledSendAt.timeIntervalSince(date)) < 60
    }
}
