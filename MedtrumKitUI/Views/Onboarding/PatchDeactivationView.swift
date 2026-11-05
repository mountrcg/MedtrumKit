import LoopKitUI
import SwiftUI

struct PatchDeactivationView: View {
    @ObservedObject var viewModel: DeactivatePatchViewModel

    @State var showingConfirmationPrompt = false
    @State private var showingSteps = false

    var body: some View {
        GuidePage(content: {
            VStack(alignment: .leading, spacing: 20) {
                PatchStepFigure(assetName: "step_remove_patch")
                    .frame(height: 200)

                Text("Deactivate the Patch", comment: "Title of the patch deactivation screen")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(
                    "When clicking on the button, you will get a Biometrics prompt. Once completed, the patch will be deactivated and you will be prompted to pair a new patch.",
                    comment: "Instructions for deactivate patch"
                )
                .fixedSize(horizontal: false, vertical: true)

                Button(action: { showingSteps = true }) {
                    Label(
                        String(
                            localized: "How to Remove the Patch",
                            comment: "Title of the step-by-step patch removal guide, and of the button opening it"
                        ),
                        systemImage: "questionmark.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.vertical, 8)
        }) {
            VStack(spacing: 12) {
                if !viewModel.deactivationError.isEmpty {
                    Text(viewModel.deactivationError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if viewModel.disableButtons {
                    Text("Cannot deactivate while a bolus is in progress", comment: "Wait for bolus to complete")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ProgressIndicatorView(state: viewModel.isDeactivating ? .indeterminantProgress : .hidden)

                Button(action: { showingConfirmationPrompt = true }) {
                    Text("Force remove", comment: "Force remove")
                        .actionButtonStyle(.secondary)
                }
                .disabled(viewModel.isDeactivating)

                Button(action: { viewModel.deactivate() }) {
                    Text("Authenticate & deactivate patch", comment: "Authenticate and deactivate label")
                        .actionButtonStyle(.destructive)
                }
                .disabled(viewModel.isDeactivating || viewModel.disableButtons)
            }
            .padding()
        }
        .alert(String(localized: "Are you sure?", comment: "title force remove"), isPresented: $showingConfirmationPrompt) {
            Button(String(localized: "Confirm", comment: "confirm force remove"), role: .destructive) {
                viewModel.forceDeactivate()
            }
        } message: {
            Text("It is recommended to deactivate first", comment: "body force remove")
        }
        .sheet(isPresented: $showingSteps) {
            PatchStepsPagerView(
                title: String(
                    localized: "How to Remove the Patch",
                    comment: "Title of the step-by-step patch removal guide, and of the button opening it"
                ),
                steps: PatchInstructionSteps.removal,
                didFinish: { showingSteps = false }
            )
        }
    }
}
