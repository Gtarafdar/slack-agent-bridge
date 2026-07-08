import SwiftUI

/// Quick Setup home — overview + entry point for the in-app setup wizard.
struct QuickSetupPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var bridge: BridgeController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AppBrandHeader(
                    subtitle: "A guided setup wizard walks you through each pane and checks your progress automatically."
                )

                if settings.tourCompleted {
                    Label("Setup complete", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Run setup wizard again") { settings.startTour() }
                } else if settings.isWizardActive {
                    Text("The setup wizard is active at the top of the window. Follow each step, then click Continue when the checkmark appears.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Jump to current step") {
                        let step = SetupWizardStep(rawValue: settings.tourStep) ?? .connectSlack
                        settings.selectedSettingsTab = step.settingsTab
                    }
                } else {
                    Button("Start setup wizard") { settings.startTour() }
                        .buttonStyle(.borderedProminent)
                }

                Divider()

                Text("Setup checklist").font(.headline)
                let snapshot = SetupWizardSnapshot.live(settings: settings, bridge: bridge)
                ForEach(SetupWizardStep.allCases) { step in
                    let status = SetupWizardValidation.stepStatus(step, snapshot: snapshot)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: status.isComplete ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(status.isComplete ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.subheadline.weight(.semibold))
                            Text(step.instructions)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let msg = status.message, !status.isComplete {
                                Text(msg)
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if settings.isWizardActive || !settings.tourCompleted {
                            Button("Go") {
                                settings.tourStep = step.rawValue
                                settings.selectedSettingsTab = step.settingsTab
                                if !settings.isWizardActive { settings.startTour() }
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}
