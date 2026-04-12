import SwiftUI

struct QuizletImportFlowView: View {
    @Environment(\.storage) private var storage
    @Environment(\.dismiss) private var dismiss

    let onImported: ((ImportResult) -> Void)?

    @StateObject private var viewModel: QuizletImportFlowViewModel
    @State private var mergeTargets: [DeckMergeTarget] = []
    @State private var mergePlan: DeckMergePlan = .empty
    @State private var showingSummary = false
    @State private var importResult: ImportResult?
    @State private var importOverlayState: ImportOperationOverlayState?

    init(storage: Storage = DataController.shared.storage, onImported: ((ImportResult) -> Void)? = nil) {
        self.onImported = onImported
        _viewModel = StateObject(wrappedValue: QuizletImportFlowViewModel(storage: storage))
    }

    var body: some View {
        ZStack {
            background
            content

            if let importOverlayState {
                ImportOperationOverlay(state: importOverlayState)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .task { await loadMergeTargets() }
        .alert("Import Complete", isPresented: $showingSummary, presenting: importResult) { _ in
            Button("Done", role: .cancel) { dismiss() }
        } message: { result in
            Text(
                "Decks added: \(result.decksInserted) • Decks updated: \(result.decksUpdated)\n" +
                "Cards added: \(result.cardsInserted) • Cards updated: \(result.cardsUpdated) • Skipped: \(result.cardsSkipped)"
            )
        }
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            DesignSystem.Colors.canvasBackground
            Circle()
                .fill(
                    RadialGradient(
                        colors: [DesignSystem.Colors.subtleOverlay, .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 240
                    )
                )
                .frame(width: 420, height: 420)
                .blur(radius: 70)
                .offset(x: 140, y: -80)
        }
        .ignoresSafeArea()
    }

    // MARK: - Content routing

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .input:
            inputView
        case .preview(let preview):
            ImportPreviewView(
                preview: preview,
                existingDecks: mergeTargets,
                mergePlan: $mergePlan,
                onImport: startImport,
                onCancel: { viewModel.reset() },
                overlayState: nil
            )
        case .importing:
            importingView
        }
    }

    // MARK: - Input view

    private var inputView: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            if let message = viewModel.errorMessage {
                Callout(message, style: .warning, title: "Could not parse export")
            }

            deckNameCard
            pasteCard
            instructionsCard

            Spacer()

            footer
        }
        .padding(DesignSystem.Spacing.xxl)
        .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
                    .frame(width: 56, height: 56)
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.primaryText)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Import from Quizlet")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                Text("Paste an exported Quizlet set and give it a deck name.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }

            Spacer()
        }
    }

    private var deckNameCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Deck name")
                .font(DesignSystem.Typography.heading)

            DesignSystemTextField(placeholder: "e.g. German Vocabulary for october eval...", text: $viewModel.deckName)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(DesignSystem.Colors.separator, lineWidth: 1)
        )
    }

    private var pasteCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("Exported content")
                    .font(DesignSystem.Typography.heading)

                Spacer()

                if !viewModel.pastedText.isEmpty {
                    let lineCount = viewModel.pastedText
                        .components(separatedBy: "\n")
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .count
                    Text("\(lineCount) \(lineCount == 1 ? "term" : "terms")")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }
            }

            TextEditor(text: $viewModel.pastedText)
                .font(DesignSystem.Typography.body)
                .frame(minHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.subtleOverlay)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.separator, lineWidth: 1)
                )
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(DesignSystem.Colors.separator, lineWidth: 1)
        )
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Label("How to export from Quizlet", systemImage: "info.circle")
                .font(DesignSystem.Typography.bodyMedium)
                .foregroundStyle(DesignSystem.Colors.primaryText)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                stepRow(number: "1", text: "Open your Quizlet set and click the three-dot menu (⋯).")
                stepRow(number: "2", text: "Choose **Export**.")
                stepRow(number: "3", text: "Keep the defaults (tab between term and definition, new line between rows).")
                stepRow(number: "4", text: "Click **Copy text** and paste it in the field above.")
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.subtleOverlay)
        )
    }

    private func stepRow(number: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Text(number)
                .font(DesignSystem.Typography.captionMedium)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .frame(width: 16, alignment: .center)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.secondaryText)

            Spacer()

            Button(action: viewModel.loadPreview) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Preview Import")
                }
                .font(DesignSystem.Typography.bodyMedium)
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.primaryText)
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canPreview)
            .opacity(viewModel.canPreview ? 1.0 : 0.5)
        }
    }

    // MARK: - Importing view

    private var importingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            ProgressView()
                .scaleEffect(1.3)

            VStack(spacing: 6) {
                Text("Importing your Quizlet cards…")
                    .font(DesignSystem.Typography.heading)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                Text("This only takes a moment.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
        }
        .padding(DesignSystem.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Import actions

    private func startImport() {
        withAnimation(DesignSystem.Animation.smooth) {
            importOverlayState = ImportOperationOverlayState(
                title: "Importing from Quizlet…",
                subtitle: "Adding cards",
                phase: .importing(progress: nil)
            )
        }
        viewModel.performImport(mergePlan: mergePlan) { result in
            withAnimation(DesignSystem.Animation.smooth) {
                importOverlayState = ImportOperationOverlayState(
                    title: "Import complete",
                    subtitle: "Added \(result.cardsInserted) cards • Updated \(result.cardsUpdated)",
                    phase: .success
                )
            }
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                await MainActor.run {
                    withAnimation(DesignSystem.Animation.smooth) {
                        importOverlayState = nil
                    }
                    importResult = result
                    showingSummary = true
                    onImported?(result)
                }
            }
        }
    }

    private func loadMergeTargets() async {
        let decks = await DeckService(storage: storage).allDecks(includeArchived: true)
        let hierarchy = DeckHierarchy(decks: decks)
        let sorted = decks.sorted { lhs, rhs in
            hierarchy.displayPath(of: lhs.id).localizedCaseInsensitiveCompare(hierarchy.displayPath(of: rhs.id)) == .orderedAscending
        }
        await MainActor.run {
            mergeTargets = sorted.map {
                DeckMergeTarget(
                    id: $0.id,
                    parentId: $0.parentId,
                    name: $0.name,
                    note: $0.note,
                    dueDate: $0.dueDate,
                    isArchived: $0.isArchived
                )
            }
        }
    }
}

#if DEBUG
#Preview("QuizletImportFlowView") {
    RevuPreviewHost { controller in
        QuizletImportFlowView(storage: controller.storage)
            .frame(width: 860, height: 700)
    }
}
#endif
