# Rework the Medtrum patch onboarding on the LoopKit `GuidePage` layout

Branch `feat/omnipod-style-patch-onboarding-ux` (base `dev` @ `85b74e8`,
HEAD `ab3690d`). Two commits: `a39df70` (port the OmniPod setup layout) and
`ab3690d` (follow-up: lay out the overviews as plain `GuidePage` list
content). Four files, net +74 / −116.

## Problem

Two problems, one structural and one visible.

**Structural.** The three Medtrum patch onboarding screens did not look or
behave like the rest of the Loop onboarding flow:

- The priming screen drew a determinate progress bar (`ProgressView(progress:)`)
  from a locally invented duration estimate, and the activation button swapped
  its own label for an `ActivityIndicator` while activating.
- The deactivation screen mixed a `List` with a loose button stack placed
  outside of it, so the three screens had three different button hierarchies
  and no shared action area:
  long localised text or an error message pushed the buttons around instead of
  the buttons staying put at the bottom.

**Visible.** The first conversion (correctly moving the screens onto
`GuidePage`) made a second problem obvious on the priming screen: a large dead
band between the step figure and the title, the figure rendered smaller than
intended, and the overview scrolling *inside* the page instead of with it.

## Root cause

1. `PatchPrimingView`, `PatchActivationView` and `PatchDeactivationView` each
   hand-rolled their own body (`VStack` in the priming screen, `List` plus an
   outside button stack in the deactivation screen) instead of using
   `LoopKitUI`'s `GuidePage`, and each drew its own busy state.
   `PatchPrimingViewModel.primeProgress` only existed to feed that bar: it is a
   0…1 fraction computed as `Double(state.primeProgress) / 240` (a hard-coded
   tick count, `PatchPrimingViewModel.swift:249`), and the old view turned that
   fraction into a `.timedProgress(finishTime:)` using `CACurrentMediaTime()` —
   i.e. it fabricated a completion time the model does not own. Nothing reads
   `primeProgress` any more.
2. `GuidePage` (`LoopKitUI/Views/GuidePage.swift`) hosts its content in a
   `List` with `insetGroupedListStyle` — wrapped in a `Section` with empty
   header/footer in the compact size class — and puts the action area in a
   sibling `VStack` below that `List`, on a
   `secondarySystemGroupedBackground` + shadow background. Consequently the
   content closure is a *List row*, not a freely sized canvas, and the `List`
   owns all scrolling.
3. The first conversion wrapped each overview in `PatchOverviewContent`
   (`PatchInstructions.swift`), a `GeometryReader` whose body is a `ScrollView`
   that sized the figure as
   `min(maxImageHeight, max(minImageHeight, room))` from `proxy.size.height`.
   A `GeometryReader` inside a `List` row is proposed a near-zero/unbounded
   height, so that measurement was meaningless — the row collapsed to the
   figure's minimum, the text was pushed under it, and the content scrolled in
   a nested scroll view.
4. Because the measurement was broken, the pattern was propped up with
   `.frame(minHeight: 400)` plus `.listRowInsets(EdgeInsets())`,
   `.listRowBackground(Color.clear)` and `.listRowSeparator(.hidden)`. The
   400 pt floor is what produced the dead band: whatever the text did not
   need, the row still reserved, and the computed figure height fell to
   `minImageHeight` (80 pt) instead of the intended 200 pt.
5. This is precisely the pattern the OmniPod setup screens avoid: their guide
   pages are a single plain row (`AttachPodView` → `LeadingImage("Pod")` +
   `InstructionList`, both plain `VStack`s) with the framework `List` doing the
   scrolling, and the progress/action controls pinned in the action area.

## Fix

### Common shape (all three screens)

- Body is `GuidePage(content:) { … }`; the overview became a single plain
  `VStack(alignment: .leading, spacing: 20)` row that starts with the step
  figure at a fixed height and then repeats the existing content hierarchy:

  ```swift
  GuidePage(content: {
      VStack(alignment: .leading, spacing: 20) {
          PatchStepFigure(assetName: "step_fill_patch")
              .frame(height: 200)

          Text("Fill and Prime the Patch", …).font(.title2).fontWeight(.semibold)
          // key points / description / "How to …" walkthrough button
      }
      .padding(.vertical, 8)
  }) {
      VStack(spacing: 12) {
          StatusSection / error text          // unchanged content and predicates
          ProgressIndicatorView(state: …)     // pinned directly above the button(s)
          Button { … } label: { Text(…).actionButtonStyle(.primary) }
      }
      .padding()
  }
  ```

- No `GeometryReader`, no nested `ScrollView`, no minimum height: the guide
  page `List` scrolls the whole page, the figure is a fixed 200 pt, and the
  row uses the default inset-grouped row styling (like a normal guide page
  row) instead of the cleared background/insets/separator overrides, which
  are removed.
- The progress indicator stays in the pinned action area, directly above the
  button(s), so it is visible regardless of how far the overview is scrolled.
- Footer spacing is unchanged (`.padding()` on the action `VStack`).

### `MedtrumKitUI/Views/Onboarding/PatchPrimingView.swift` (+14 / −17)

- Overview row: `step_fill_patch` figure, the title, the
  `PatchKeyPoints` (minimum-fill and not-on-body notes), the summary text and
  the "How to Fill and Prime the Patch" walkthrough button.
- Action area: `statusSection`, `ProgressIndicatorView(state: progressState)`
  and the "Start priming" button styled `.actionButtonStyle(.primary)` with
  its original `.disabled(!viewModel.canStartPriming)` guard.
- `progressState` maps `viewModel.isPriming ? .indeterminantProgress : .hidden`.
  Determinate progress was removed deliberately: the screen has no
  model-owned completion time, so no finish time is fabricated.
- `statusSection` no longer draws its own rounded `secondarySystemBackground`
  box: it now sits inline in the pinned action area (on the action area's
  grouped background), while typography, failure colouring, reservoir level
  and the retry button are unchanged.

### `MedtrumKitUI/Views/Onboarding/PatchActivationView.swift` (+12 / −9)

- Overview row: `step_insert_needle` figure, the title, the
  "Priming is complete …" instructions and the "How to Attach the Patch"
  button.
- Action area: activation error text (`.font(.footnote)`),
  `ProgressIndicatorView(state: viewModel.isActivating ? .indeterminantProgress : .hidden)`
  and the "Activate Patch" button with `.actionButtonStyle(.primary)` and the
  previous `.disabled(viewModel.isActivating)` guard.
- The in-button `ActivityIndicator` swap is gone; the button keeps a stable
  label in every state. The navigation-bar Cancel button is unchanged.

### `MedtrumKitUI/Views/Onboarding/PatchDeactivationView.swift` (+48 / −42)

- The former `List` with its sections became one plain overview row
  (`step_remove_patch` figure, "Deactivate the Patch" title, the biometrics
  explanation, the "How to Remove the Patch" button). The now-redundant
  `.listStyle(InsetGroupedListStyle())` / `.edgesIgnoringSafeArea(.bottom)`
  modifiers were dropped because `GuidePage` owns list styling and safe areas.
- Action area, in order: deactivation error *or* the "Cannot deactivate while
  a bolus is in progress" note (both `.font(.footnote)`, red, multiline),
  `ProgressIndicatorView(state: viewModel.isDeactivating ? .indeterminantProgress : .hidden)`,
  the secondary "Force remove" button, and the destructive
  "Authenticate & deactivate patch" button, each keeping its original disabled
  conditions (`isDeactivating`, `disableButtons`).
- The force-remove confirmation alert and the removal walkthrough sheet keep
  their localisation keys and comments.

### `MedtrumKitUI/Views/Onboarding/PatchInstructions.swift` (−48)

- `PatchOverviewContent` deleted in full: the `GeometryReader`, the nested
  `ScrollView` (`scrollBounceBehavior(.basedOnSize)`,
  `scrollIndicatorsFlash(onAppear:)`), the `onGeometryChange` content-height
  state and the `imageHeight(available:)` computation. It has no remaining
  call site (`grep -rn PatchOverviewContent` over the repo: no hits).
- `PatchStepFigure` and `PatchStepsPagerView` (the independent walkthrough
  pager, which legitimately has its own `ScrollView`) are untouched.

### Behaviour that did not change

- Every user-facing string keeps its English source and its `comment:`
  localisation hint, so existing translations resolve unchanged; no new
  localisation keys.
- No view-model, persistence or BLE changes: the change is view-layer only.
  `PatchPrimingViewModel.primeProgress` is no longer read by the view; it is
  not removed by this PR (see *Not included*).
- Step figures and assets (`step_fill_patch`, `step_insert_needle`,
  `step_remove_patch`), `PatchInstructionSteps.priming` / `.activation` /
  `.removal` and the walkthrough pager titles are unchanged.

## Not included

- **No compact-height figure variant.** The figure is a fixed 200 pt at every
  size class. OmniPod's `LeadingImage` drops to 70 pt in the compact vertical
  size class, and the architecture note for this change proposed 120 pt via a
  `PatchOverviewFigure` wrapper; that wrapper was not implemented, so the
  Medtrum figure keeps one height in portrait and landscape. Follow-up if the
  landscape layout needs it.
- `ActivityIndicator` is still used by the settings screens
  (`MedtrumKitSettings.swift`, `PatchSettingsView.swift`,
  `ManualTempBasalView.swift`); only the three onboarding screens switched to
  `ProgressIndicatorView`.
- `PatchPrimingViewModel.primeProgress` is now dead from the view's side but is
  left in place; removing view-model API is out of scope here.
- No localisation file changes, no test-target changes, no CI changes.
- No simulator screenshots have been captured yet — the placeholders below are
  the capture plan, not evidence.

## Testing

Independent review card: `t_7994c088` — **VERDICT: APPROVED** for
`ab3690d72ab1a14eae192d8cdb1de610310561ca`.

| Check | Command | Result |
| --- | --- | --- |
| Whitespace / conflict sanity | `git diff --check 85b74e8..HEAD` | exit 0, no output |
| Syntax parse, all four changed sources, run individually | `xcrun swiftc -parse PatchPrimingView.swift` (and `PatchActivationView.swift`, `PatchDeactivationView.swift`, `PatchInstructions.swift`, from `MedtrumKitUI/Views/Onboarding`) | all exit 0, no diagnostics |
| Dead-code check | `grep -rn PatchOverviewContent --include=*.swift .` | no hits |
| Tai workspace discovery | `/Users/RCG/Projects/Tai/Trio.xcworkspace` lists the `MedtrumKitTests` scheme | discovered, not built (see below) |

Reviewer's concrete finding: the three `GuidePage` content closures are plain
`VStack` list content starting with `PatchStepFigure(...).frame(height: 200)`;
`PatchOverviewContent` (GeometryReader, nested `ScrollView`, dynamic height
state) is gone; the min-height/row-inset/background/separator workarounds are
gone; the only remaining `ScrollView` in the onboarding folder is
`PatchStepCard`, the walkthrough pager, not an overview row; each action area
keeps `ProgressIndicatorView` immediately above its button(s) with unchanged
busy/error/disabled predicates; localised text/comments, view-model calls and
`.padding()` footer spacing are unchanged. Re-verified at documentation time on
2026-10-29: `git diff --check` and the four `swiftc -parse` runs still exit 0.

### About the full build

There is **no clean standalone `xcodebuild` gate for this repository**:
`MedtrumKit.xcodeproj` links `LoopKit.framework` and `LoopKitUI.framework` from
`BUILT_PRODUCTS_DIR`, and those products only exist when the project is built
inside the Tai workspace, which is where the LoopKit/LoopKitUI sources and the
`GuidePage` / `ProgressIndicatorView` / `actionButtonStyle` APIs live.

- The reviewer intentionally did **not** use a Tai-workspace build as
  verification: `/Users/RCG/Projects/Tai/MedtrumKit` is detached at
  `c33699595b6f636d8ca1bff377a8765df5597c34`, so a workspace build would have
  compiled a different submodule commit than the reviewed `ab3690d`.
- An earlier, documentation-time standalone `MedtrumKit` build of the worktree
  that became `a39df70` (simulator, `arm64`, framework search paths pointing at
  previously built LoopKit/LoopKitUI products from the Tai DerivedData) reported
  `** BUILD SUCCEEDED **`, 101 Swift compile jobs. That is borrowed-framework
  evidence that the views compile and link, not a release gate, and it was
  **not** re-run for `ab3690d` (which only removes a struct and changes view
  bodies already covered by the parse checks above).

### Not verified

- No simulator or device run: neither commit's layout has been exercised
  visually. The before/after screenshots below still need to be taken.
- No unit or UI tests executed (`MedtrumKitTests` was not built or run for this
  change).
- `swiftc -typecheck` over the whole `MedtrumKitUI` folder in isolation is not
  possible - it fails on MedtrumKit-internal types such as `AlarmSettings` and
  `MedtrumPumpManager`.

### Manual checklist for the reviewer

1. Priming screen: the figure sits directly above the title with no dead band,
   the page scrolls as a whole (no inner scroll area), "Start priming" stays
   pinned at the bottom, `ProgressIndicatorView` shows an indeterminate spinner
   while priming and disappears afterwards; reservoir level appears when priming
   ends; failure text turns red and the retry button appears.
2. Activation screen: overview with `step_insert_needle`, error text above the
   pinned "Activate Patch" button, button disabled while activating, Cancel in
   the navigation bar still dismisses.
3. Deactivation screen: overview with `step_remove_patch`, "How to Remove the
   Patch" opens the pager sheet, "Force remove" opens the "Are you sure?"
   confirmation, "Authenticate & deactivate patch" is destructive styled and
   disabled while deactivating or while a bolus is in progress (with the red
   note).
4. Long localised strings (e.g. German) wrap without clipping in both the
   overview row and the action area.
5. Compact and regular horizontal size classes, plus the compact vertical size
   class (landscape), render the pinned action area at the bottom without a
   visible seam; check whether the 200 pt figure is acceptable there.
6. Scroll to the bottom of each overview: the last content element is not
   stranded from the footer.

## Screenshots

Before = `a39df70` (the `PatchOverviewContent` / `minHeight: 400` state),
after = `ab3690d`. Capture with
`xcrun simctl io booted screenshot ~/Desktop/<name>.png`, from the Tai
workspace with the submodule checked out at the respective commit
(`cd /Users/RCG/Projects/Tai/MedtrumKit && git checkout <commit>`), navigating
to the patch setup flow.

Priming screen

- before: `![Priming overview before](TODO-medtrum-priming-before.png)`
- after: `![Priming overview after](TODO-medtrum-priming-after.png)`

Activation screen

- before: `![Activation overview before](TODO-medtrum-activation-before.png)`
- after: `![Activation overview after](TODO-medtrum-activation-after.png)`

Deactivation screen

- before: `![Deactivation overview before](TODO-medtrum-deactivation-before.png)`
- after: `![Deactivation overview after](TODO-medtrum-deactivation-after.png)`

Scrolled-to-footer state (shows that the progress indicator stays pinned and
that the overview is not stranded): `![Pinned action area](TODO-medtrum-action-area.png)`

## Review chain (record)

1. First review rejected the initial `PatchPrimingView` progress mapping
   because it derived a `.timedProgress(finishTime:)` from a hard-coded 240 s
   estimate plus `CACurrentMediaTime()` - an invented completion time the model
   does not own.
2. Rework replaced it with
   `viewModel.isPriming ? .indeterminantProgress : .hidden`; re-review returned
   `VERDICT: APPROVED`.
3. Manual verification of the converted screens then showed the layout defect
   described under *Root cause*; the follow-up commit `ab3690d` removed
   `PatchOverviewContent` and the `minHeight` workaround, and review card
   `t_7994c088` approved it.

## Branch state

- Branch: `feat/omnipod-style-patch-onboarding-ux`
- Base: `dev` @ `85b74e8`
- `a39df70` — `feat: port OmniPod setup layout to patch onboarding screens`
  (pushed; `origin/feat/omnipod-style-patch-onboarding-ux` is at this commit)
- `ab3690d` — `fix: lay out patch onboarding overviews as plain GuidePage list content`
  (HEAD, **unpushed**, 1 commit ahead of origin)
- Diff vs `85b74e8`: 4 files, +74 / −116
  (`PatchPrimingView.swift` +14/−17, `PatchActivationView.swift` +12/−9,
  `PatchDeactivationView.swift` +48/−42, `PatchInstructions.swift` +0/−48)
- `PR_DRAFT.md` is untracked and is part of no commit; do not commit it.
- Suggested PR title: `Rework the Medtrum patch onboarding on the GuidePage layout`
