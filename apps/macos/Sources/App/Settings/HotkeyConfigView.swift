import SwiftUI

/// Hotkey configuration section: displays current hotkey, allows recording a new one,
/// and warns about potential system conflicts.
struct HotkeyConfigView: View {
    @ObservedObject var hotkeyManager: HotkeyManager

    @State private var pendingCombo: KeyCombo?
    @State private var conflicts: [String] = []
    @State private var showConflictWarning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Hotkey", systemImage: "keyboard")
                .font(.headline)

            currentHotkeyDisplay
            recordButton
            conflictWarningView
        }
        .padding(.vertical, 8)
    }

    // MARK: - Current Hotkey Display

    private var currentHotkeyDisplay: some View {
        HStack {
            Text("Activation shortcut:")
                .foregroundColor(.secondary)
                .font(.subheadline)

            Spacer()

            Text(hotkeyManager.currentCombo.displayString)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        Button(action: toggleRecording) {
            HStack {
                if hotkeyManager.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Press key combination… (Esc to cancel)")
                        .font(.subheadline)
                } else {
                    Image(systemName: "record.circle")
                    Text("Record New Hotkey")
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    // MARK: - Conflict Warning

    @ViewBuilder
    private var conflictWarningView: some View {
        if showConflictWarning, !conflicts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Potential conflicts detected:", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)

                ForEach(conflicts, id: \.self) { conflict in
                    Text("• \(conflict)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Button("Use Anyway") {
                        applyPendingCombo()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Cancel") {
                        cancelPending()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.1))
            )
        }
    }

    // MARK: - Actions

    private func toggleRecording() {
        if hotkeyManager.isRecording {
            hotkeyManager.stopRecording()
        } else {
            showConflictWarning = false
            pendingCombo = nil
            conflicts = []

            hotkeyManager.startRecording { combo in
                let detectedConflicts = combo.potentialConflicts
                if detectedConflicts.isEmpty {
                    hotkeyManager.updateHotkey(combo)
                } else {
                    pendingCombo = combo
                    conflicts = detectedConflicts
                    showConflictWarning = true
                }
            }
        }
    }

    private func applyPendingCombo() {
        if let combo = pendingCombo {
            hotkeyManager.updateHotkey(combo)
        }
        cancelPending()
    }

    private func cancelPending() {
        pendingCombo = nil
        conflicts = []
        showConflictWarning = false
    }
}
