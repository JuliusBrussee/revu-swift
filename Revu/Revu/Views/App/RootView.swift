import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.storage) private var storage
    @EnvironmentObject private var storeEvents: StoreEvents
    @EnvironmentObject private var commandCenter: WorkspaceCommandCenter
    @AppStorage("revu.hasCompletedOnboarding") private var persistedOnboardingComplete = false
    @AppStorage("revu.hasSeenQuickFindHint") private var hasSeenQuickFindHint = false
    @State private var selection: SidebarItem? = nil
    @State private var selectedDeck: Deck?
    @State private var selectedFolder: Deck?
    @State private var selectedExam: Exam?
    @State private var selectedStudyGuide: StudyGuide?
    @State private var fileImporterPresented = false
    @State private var fileExporterPresented = false
    @State private var importPreview: ImportPreview?
    @State private var importResult: ImportResult?
    @State private var exportDocument: DeckExportDocument?
    @State private var exportContentType: UTType = .json
    @State private var exportFilename: String = "revu.json"
    @State private var exportFormatDialogPresented = false
    @State private var pendingExportDecks: [Deck] = []
    @State private var showingImportSummary = false
    @State private var errorMessage: String?
    @State private var showingErrorAlert = false
    @State private var cachedImportSource: ImportSource?
    @State private var cachedImportDescriptorID: String?
    @State private var importPlan: DeckMergePlan = .empty
    @State private var importTargets: [DeckMergeTarget] = []
    @State private var importContext: ImportInvocationContext = .workspace
    @State private var importOverlayState: ImportOperationOverlayState?
    @State private var toast: ToastData?
    @AppStorage("revu.sidebarPresentation") private var sidebarPresentationRaw = SidebarPresentation.expanded.rawValue
    @AppStorage("revu.sidebarLastVisiblePresentation") private var lastVisibleSidebarPresentationRaw = SidebarPresentation.expanded.rawValue
    @AppStorage("revu.sidebarExpandedWidth") private var sidebarExpandedWidthRaw: Double = 280
    @State private var isInspectorVisible = false
    @State private var hasAutoOpenedInspector = false
    @StateObject private var workspaceSelection = WorkspaceSelection()
    @StateObject private var quickCommandViewModel = QuickCommandViewModel()
    @StateObject private var navigationHistory = WorkspaceNavigationHistory()
    @StateObject private var courseViewModel = CourseViewModel()
    @EnvironmentObject private var workspacePreferences: WorkspacePreferences
    @State private var selectedCourse: Course?
    @State private var isCourseSetupPresented = false
    @State private var isQuickFindPresented = false
    @State private var isDeckEditorPresented = false
    @State private var deckEditorTarget: Deck? = nil
    @State private var deckEditorParentId: UUID? = nil
    @State private var deckEditorKind: Deck.Kind = .deck
    @State private var deckPendingDeletion: Deck?
    @State private var isCreatingExam: Bool = false
    @State private var appearanceMode: AppearanceMode = .system
    @State private var isOnboardingPresented = false
    @State private var activeSmartStudyFilter: SmartFilter?
    @State private var isImportGuidePresented = false
    @State private var isQuizletImportPresented = false
    @State private var hasSeenQuickFindSignal = false
    @State private var hasSeenOnboardingSignal = false
    @State private var previousSelection: SidebarItem? = nil
    @State private var examPendingDeletion: Exam?
    @State private var studyGuidePendingDeletion: StudyGuide?
    @State private var coursePendingDeletion: Course?
    @State private var courseToEdit: Course?
    @State private var saveStatusService = SaveStatusService()
    @State private var streakPillViewModel: StreakPillViewModel?
    @State private var pomodoroService = PomodoroService()
    @State private var pomodoroSoundService = PomodoroSoundService()

    private var sidebarPresentation: SidebarPresentation {
        get { SidebarPresentation(rawValue: sidebarPresentationRaw) ?? .expanded }
        nonmutating set { sidebarPresentationRaw = newValue.rawValue }
    }

    private var lastVisibleSidebarPresentation: SidebarPresentation {
        get { SidebarPresentation(rawValue: lastVisibleSidebarPresentationRaw) ?? .expanded }
        nonmutating set { lastVisibleSidebarPresentationRaw = newValue.rawValue }
    }

    private var sidebarExpandedWidth: CGFloat {
        get { CGFloat(sidebarExpandedWidthRaw) }
        nonmutating set { sidebarExpandedWidthRaw = Double(newValue) }
    }

    private var isDeleteDialogPresented: Binding<Bool> {
        Binding<Bool>(
            get: { deckPendingDeletion != nil },
            set: { newValue in
                if !newValue { deckPendingDeletion = nil }
            }
        )
    }

	    var body: some View {
	        let sidebarBinding = Binding<SidebarPresentation>(
	            get: { sidebarPresentation },
	            set: { newValue in
	                if newValue.isVisible {
	                    lastVisibleSidebarPresentation = newValue
	                }
	                sidebarPresentation = newValue
	            }
	        )
	        let sidebarWidthBinding = Binding<CGFloat>(
	            get: { sidebarExpandedWidth },
	            set: { sidebarExpandedWidth = $0 }
	        )
	        let baseLayout = AnyView(makeWorkspaceLayout(sidebarBinding: sidebarBinding, sidebarWidthBinding: sidebarWidthBinding))

	        let chrome = AnyView(applyChrome(to: baseLayout))
	        let importExport = AnyView(applyImportExport(to: chrome))
	        let sheets = AnyView(applySheets(to: importExport))
	        let dialogs = AnyView(applyDialogs(to: sheets))
	        let events = AnyView(applyEventHandlers(to: dialogs))
	        return AnyView(applyOverlays(to: events))
	    }

    private func makeWorkspaceLayout(
        sidebarBinding: Binding<SidebarPresentation>,
        sidebarWidthBinding: Binding<CGFloat>
    ) -> some View {
        let inspector = WorkspaceInspector(selection: selection, deck: selectedDeck, onClose: hideInspector)
        return WorkspaceLayout(
            sidebarPresentation: sidebarBinding,
            sidebarExpandedWidth: sidebarWidthBinding,
            isInspectorVisible: $isInspectorVisible,
            sidebar: { workspaceSidebar },
            canvas: { detailCanvas },
            inspector: { inspector }
        )
    }

    private func applyChrome<V: View>(to view: V) -> some View {
        view
            .toolbar { windowToolbar }
            .revuWindowToolbarBackground(DesignSystem.Colors.sidebarBackground)
            .environmentObject(workspaceSelection)
            .preferredColorScheme(colorScheme(for: appearanceMode))
    }

    private func applyImportExport<V: View>(to view: V) -> some View {
        view
            .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: DeckImportCoordinator.supportedContentTypes) { result in
                handleFileImport(result: result)
            }
            .fileExporter(
                isPresented: $fileExporterPresented,
                document: exportDocument,
                contentType: exportContentType,
                defaultFilename: exportFilename
            ) { result in
                Task { @MainActor in
                    exportDocument = nil
                    handleFileExportResult(result)
                }
            }
    }

    private func applySheets<V: View>(to view: V) -> some View {
        view
            .sheet(isPresented: $isDeckEditorPresented, onDismiss: resetDeckEditorTarget) {
                DeckEditorView(deck: deckEditorTarget, defaultParentId: deckEditorParentId, defaultKind: deckEditorKind) { deck in
                    Task { await handleDeckSaved(deck) }
                }
            }
            .sheet(isPresented: $isCreatingExam) {
                Text("Exam editor")
                    .task {
                        await createNewExam()
                        isCreatingExam = false
                    }
            }
            .sheet(item: $importPreview, onDismiss: resetImportPreview) { preview in
                importPreviewSheet(for: preview)
            }
            .sheet(isPresented: $isImportGuidePresented) {
                ImportGuideSheetView(
                    onDismiss: { isImportGuidePresented = false },
                    onChooseFile: {
                        isImportGuidePresented = false
                        Task { @MainActor in
                            beginFileImportFlow()
                        }
                    },
                    onQuizletImport: {
                        isImportGuidePresented = false
                        isQuizletImportPresented = true
                    }
                )
            }
            .sheet(isPresented: $isQuizletImportPresented) {
                QuizletImportFlowView()
            }
            .sheet(isPresented: $isCourseSetupPresented, onDismiss: { courseToEdit = nil }) {
                CourseSetupView(
                    existingCourse: courseToEdit,
                    onCourseCreated: { course in
                        Task {
                            await CourseService(storage: storage).upsert(course: course)
                            await MainActor.run {
                                isCourseSetupPresented = false
                                courseToEdit = nil
                                selection = .course(course.id)
                            }
                        }
                    },
                    onCancel: {
                        isCourseSetupPresented = false
                        courseToEdit = nil
                    }
                )
            }
    }

    private func applyDialogs<V: View>(to view: V) -> some View {
        view
            .alert("Import Complete", isPresented: $showingImportSummary, presenting: importResult) { _ in
                Button("OK", role: .cancel) {}
            } message: { result in
                importSummaryMessage(for: result)
            }
            .alert("Error", isPresented: $showingErrorAlert, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
            .confirmationDialog(
                "Delete Deck?",
                isPresented: isDeleteDialogPresented,
                titleVisibility: .visible
            ) {
                let name = deckPendingDeletion?.name ?? "Deck"
                Button("Delete \(name)", role: .destructive) {
                    if let deck = deckPendingDeletion {
                        Task { await deleteDeck(deck) }
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Deleting this deck will also remove all of its cards. This action cannot be undone.")
            }
            .confirmationDialog(
                exportDialogTitle(for: pendingExportDecks),
                isPresented: $exportFormatDialogPresented,
                presenting: pendingExportDecks
            ) { decks in
                ForEach(DeckExportFormat.allCases) { format in
                    Button {
                        exportFormatDialogPresented = false
                        performExport(for: decks, format: format)
                    } label: {
                        Label(format.displayName, systemImage: format.iconName)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { decks in
                Text(exportDialogMessage(for: decks))
            }
            .confirmationDialog(
                "Delete Exam?",
                isPresented: Binding(
                    get: { examPendingDeletion != nil },
                    set: { if !$0 { examPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Exam", role: .destructive) {
                    if let exam = examPendingDeletion {
                        Task {
                            try? await storage.deleteExam(id: exam.id)
                            await MainActor.run {
                                if selection == .exam(exam.id) { selection = nil }
                                examPendingDeletion = nil
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { examPendingDeletion = nil }
            } message: {
                Text("This will permanently delete the exam and all its questions.")
            }
            .confirmationDialog(
                "Delete Study Guide?",
                isPresented: Binding(
                    get: { studyGuidePendingDeletion != nil },
                    set: { if !$0 { studyGuidePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Study Guide", role: .destructive) {
                    if let guide = studyGuidePendingDeletion {
                        Task {
                            try? await storage.deleteStudyGuide(id: guide.id)
                            await MainActor.run {
                                if selection == .studyGuide(guide.id) { selection = nil }
                                studyGuidePendingDeletion = nil
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { studyGuidePendingDeletion = nil }
            } message: {
                Text("This will permanently delete the study guide and all its content.")
            }
            .confirmationDialog(
                "Delete Course?",
                isPresented: Binding(
                    get: { coursePendingDeletion != nil },
                    set: { if !$0 { coursePendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Course", role: .destructive) {
                    if let course = coursePendingDeletion {
                        Task {
                            await CourseService(storage: storage).deleteCourse(id: course.id)
                            await MainActor.run {
                                if selection == .course(course.id) { selection = nil }
                                coursePendingDeletion = nil
                            }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { coursePendingDeletion = nil }
            } message: {
                Text("This will permanently delete the course. Decks and materials linked to this course will not be deleted.")
            }
    }

    private func applyEventHandlers<V: View>(to view: V) -> some View {
        view
            .onChange(of: selection) { previous, newSelection in
                handleSelectionChange(previous: previous, newSelection: newSelection)
            }
            .onAppear {
                prepareInitialSelection()
                loadSettingsState()
            }
            .onReceive(storeEvents.$tick) { _ in
                refreshSelectionAsync()
                loadSettingsState()
            }
            .task {
                saveStatusService.observe(storeEvents)
                let vm = StreakPillViewModel(storage: storage)
                streakPillViewModel = vm
                vm.observe(storeEvents)
            }
            .onReceive(commandCenter.$quickFindToken) { token in
                guard token > 0 else { return }
                guard hasSeenQuickFindSignal else {
                    hasSeenQuickFindSignal = true
                    return
                }
                hasSeenQuickFindHint = true
                presentQuickFindAsync()
            }
            .onReceive(commandCenter.$onboardingToken) { _ in
                guard hasSeenOnboardingSignal else {
                    hasSeenOnboardingSignal = true
                    return
                }
                presentOnboarding(fromSettings: true)
            }
            .onReceive(workspaceSelection.$focusedCard) { _ in
                adjustInspectorVisibilityAsync()
            }
    }

    private func applyOverlays<V: View>(to view: V) -> some View {
        view
            .overlay(alignment: .bottomTrailing) { toastOverlay }
            .overlay { quickFindOverlay }
            .overlay { onboardingOverlay }
    }
    
    private func colorScheme(for mode: AppearanceMode) -> ColorScheme? {
        switch mode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
    
    private func loadSettingsState() {
        Task {
            if let settings = try? await DataController.shared.loadSettings() {
                await MainActor.run {
                    appearanceMode = settings.appearanceMode
                    let completed = settings.hasCompletedOnboarding || persistedOnboardingComplete
                    isOnboardingPresented = !completed
                }
            }
        }
    }

    @MainActor
    private func completeOnboardingFlow() {
        Task {
            do {
                var settings = try await DataController.shared.loadSettings()
                settings.hasCompletedOnboarding = true
                await DataController.shared.save(settings: settings)
                await MainActor.run {
                    persistedOnboardingComplete = true
                    isOnboardingPresented = false
                }
            } catch {
                await MainActor.run {
                    showError("Couldn't save onboarding: \(error.localizedDescription)")
                }
            }
        }
    }

    private func presentOnboarding(fromSettings: Bool = false) {
        Task {
            if fromSettings {
                do {
                    var settings = try await DataController.shared.loadSettings()
                    settings.hasCompletedOnboarding = false
                    await DataController.shared.save(settings: settings)
                } catch {
                    await MainActor.run {
                        showError("Couldn't prepare onboarding: \(error.localizedDescription)")
                    }
                }
            }
            await MainActor.run {
                withAnimation(DesignSystem.Animation.smooth) {
                    persistedOnboardingComplete = false
                    isOnboardingPresented = true
                }
            }
        }
    }

    private func handleSelectionChange(previous: SidebarItem?, newSelection: SidebarItem?) {
        if previous != newSelection {
            Task { @MainActor in workspaceSelection.clearCard() }
            activeSmartStudyFilter = nil

            // Push to navigation history (unless we're navigating via back/forward)
            if let newSelection = newSelection, !isNavigatingViaHistory {
                navigationHistory.push(newSelection)
            }
        }

        Task { await updateSelection(newSelection) }
    }

    @State private var isNavigatingViaHistory = false

    private func handleNavigationBack() {
        guard let item = navigationHistory.goBack() else { return }
        isNavigatingViaHistory = true
        selection = item
        isNavigatingViaHistory = false
    }
    
    private func handleNavigationForward() {
        guard let item = navigationHistory.goForward() else { return }
        isNavigatingViaHistory = true
        selection = item
        isNavigatingViaHistory = false
    }

    private func prepareInitialSelection() {
        Task {
            let currentSelection = await MainActor.run { selection }
            if currentSelection == nil {
                let initial = await defaultSelection()
                await MainActor.run { selection = initial }
                await updateSelection(initial)
            }
        }
    }

    private func refreshSelectionAsync() {
        Task { await refreshSelection() }
    }

    private func presentQuickFindAsync() {
        Task { @MainActor in presentQuickFind() }
    }

    @MainActor
    private func beginFileImportFlow(targetDeckID: UUID? = nil) {
        importContext = targetDeckID.map { .deck($0) } ?? .workspace
        importPlan = .empty
        fileImporterPresented = true
    }

    private func adjustInspectorVisibilityAsync() {
        Task { @MainActor in adjustInspectorVisibility(for: selection) }
    }

    @MainActor
    private func handleFileExportResult(_ result: Result<URL, Error>) {
        if case let .failure(error) = result {
            showError("Export failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func resetImportPreview() {
        importPreview = nil
        cachedImportSource = nil
        cachedImportDescriptorID = nil
        importPlan = .empty
        importTargets = []
        importContext = .workspace
        importOverlayState = nil
    }

    @ViewBuilder
    private func importPreviewSheet(for preview: ImportPreview) -> some View {
        ImportPreviewView(
            preview: preview,
            existingDecks: importTargets,
            mergePlan: $importPlan,
            onImport: performImport,
            onCancel: { resetImportPreview() },
            overlayState: importOverlayState
        )
    }

    private func importSummaryMessage(for result: ImportResult) -> Text {
        Text(
            "Decks added: \(result.decksInserted) • Decks updated: \(result.decksUpdated)\n" +
            "Cards added: \(result.cardsInserted) • Cards updated: \(result.cardsUpdated) • Skipped: \(result.cardsSkipped)"
        )
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = toast {
            ToastView(title: toast.title, message: toast.message)
                .padding()
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var quickFindOverlay: some View {
        if isQuickFindPresented {
            ZStack {
                Color(light: Color.black.opacity(0.15), dark: Color.black.opacity(0.5))
                    .ignoresSafeArea()
                    .onTapGesture { dismissQuickFind() }
                QuickCommandPalette(
                    viewModel: quickCommandViewModel,
                    onSelect: { result in handleQuickCommandSelection(result) },
                    onDismiss: { dismissQuickFind() }
                )
                .transition(.scale.combined(with: .opacity))
            }
            .zIndex(1)
        }
    }

    @ViewBuilder
    private var onboardingOverlay: some View {
        if isOnboardingPresented {
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                OnboardingFlowView(
                    onComplete: { completeOnboardingFlow() },
                    onSkip: { completeOnboardingFlow() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DesignSystem.Colors.window.ignoresSafeArea())
                .accessibilityAddTraits(.isModal)
                .transition(.opacity)
            }
            .zIndex(2)
        }
    }

    private var workspaceSidebar: some View {
        SidebarView(
            selection: $selection,
            displayMode: sidebarPresentation == .compact ? .compact : .expanded,
            selectedDeck: selectedDeck,
            onNewDeck: { openDeckEditor() },
            onNewFolder: { openDeckEditor(kind: .folder) },
            onNewExam: { isCreatingExam = true },
            onNewStudyGuide: {
                Task { @MainActor in
                    await createNewStudyGuide()
                }
            },
            onNewCourse: { isCourseSetupPresented = true },
            onNewSubdeck: { deck in openDeckEditor(parentId: deck.id) },
            onMoveDeck: { deck, parentId in
                Task { await DeckService(storage: storage).reparent(deckId: deck.id, toParentId: parentId) }
            },
            onRenameDeck: { deck in openDeckEditor(deck: deck) },
            onDeleteDeck: prepareDeckDeletion,
            onArchiveDeck: archiveDeck,
            onUnarchiveDeck: unarchiveDeck,
            onExportDeck: exportDeck,
            onMergeDecks: { source, destination in mergeDeck(source: source, into: destination) },
            onDeckOrderChange: { saveDeckOrder($0) },
            onImport: { isImportGuidePresented = true },
            onExport: prepareExport,
            onDeleteExam: { exam in examPendingDeletion = exam },
            onDeleteStudyGuide: { guide in studyGuidePendingDeletion = guide },
            onDeleteCourse: { course in coursePendingDeletion = course },
            onEditCourse: { course in
                courseToEdit = course
                isCourseSetupPresented = true
            }
        )
        .padding(.top, DesignSystem.Spacing.md)
    }

    private var detailCanvas: some View {
        detailView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .learningIntelligence:
            LearningIntelligenceView()
        case .deckOrganizer:
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Text("Deck organizer is temporarily disabled")
                    .font(DesignSystem.Typography.hero)
                Text("Manual ordering was removed because it was unreliable. We may re-introduce it later with a sturdier, well-tested reorder model.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }
            .padding(DesignSystem.Spacing.xl)
        case .folder(let id):
            if let folder = selectedFolder, folder.id == id {
                FolderCanvasView(folder: folder, selection: $selection)
            } else {
                placeholder("Select a folder")
            }
        case .deck(let id):
            if let deck = selectedDeck, deck.id == id {
                DeckDetailView(
                    deck: deck,
                    onImportDeck: { beginFileImportFlow(targetDeckID: $0.id) },
                    onShowImportGuide: { isImportGuidePresented = true }
                )
            } else {
                placeholder("Select a deck")
            }
        case .exam(let id):
            if let exam = selectedExam, exam.id == id {
                ExamSurfaceView(exam: exam)
            } else {
                placeholder("Select an exam")
            }
        case .studyGuide(let id):
            if let guide = selectedStudyGuide, guide.id == id {
                StudyGuideEditorView(studyGuide: guide)
            } else {
                placeholder("Select a study guide")
            }
        case .course(let id):
            if let course = selectedCourse, course.id == id {
                CourseDetailView(
                    course: course,
                    viewModel: courseViewModel,
                    onOpenDeck: { selection = .deck($0) },
                    onOpenExam: { selection = .exam($0) },
                    onOpenStudyGuide: { selection = .studyGuide($0) }
                )
            } else {
                placeholder("Select a course")
            }
        case .tag(let tag):
            TagDetailCanvas(tag: tag, storage: storage)
        case .smart(let filter):
            if activeSmartStudyFilter == filter {
                StudySessionSurface {
                    smartFilterSession(for: filter)
                }
            } else {
                SmartFilterCanvas(filter: filter, storage: storage, onStudy: {
                    startStudySession(for: filter)
                })
            }
        case .stats:
            StatsView()
        case .settings:
            SettingsView()
        case .none:
            placeholder("Choose an item")
        }
    }

    private func smartFilterSubtitle(for filter: SmartFilter) -> String {
        filter.subtitle
    }
    
    private func filterInspectorMessage(for filter: SmartFilter) -> String {
        switch filter {
        case .dueToday:
            return "Stay on pace by clearing cards scheduled today. Inspector insights highlight streaks and upcoming hotspots."
        case .new:
            return "Use this filter to seed fresh material. We'll surface creation templates and drafting tips as they become available."
        case .suspended:
            return "Review why cards were paused and when to safely reintroduce them. Future updates will suggest reinstatement windows."
        }
    }

    private func toggleSidebar() {
        withAnimation(DesignSystem.Animation.layout) {
            if sidebarPresentation == .hidden {
                sidebarPresentation = lastVisibleSidebarPresentation
            } else {
                lastVisibleSidebarPresentation = sidebarPresentation
                sidebarPresentation = .hidden
            }
        }
    }

    @ToolbarContentBuilder
    private var windowToolbar: some ToolbarContent {
        // LEFT: Unified navigation cluster
        ToolbarItem(placement: .navigation) {
            TopBarNavCluster(
                canGoBack: navigationHistory.canGoBack,
                canGoForward: navigationHistory.canGoForward,
                onToggleSidebar: toggleSidebar,
                onBack: handleNavigationBack,
                onForward: handleNavigationForward
            )
            .controlSize(.small)
        }
        .sharedBackgroundVisibility(.hidden)

        // CENTER: Breadcrumb trail + Quick Find
        ToolbarItem(placement: .principal) {
            BreadcrumbNavView(
                crumbs: breadcrumbs,
                onNavigate: { item in
                    selection = item
                    navigationHistory.push(item)
                },
                onQuickFind: commandCenter.openQuickFind
            )
            .fixedSize(horizontal: true, vertical: false)
            .controlSize(.small)
        }

        // RIGHT: Context actions (deck-specific)
        ToolbarItem(placement: .primaryAction) {
            if case .deck = selection {
                ViewModeToggle(mode: $workspacePreferences.cardViewMode)
            }
        }

        // RIGHT: Session status tray (streak + pomodoro + save)
        ToolbarItem(placement: .primaryAction) {
            if let vm = streakPillViewModel {
                TopBarSessionTray(
                    reviewed: vm.todayReviewed,
                    due: vm.todayDue,
                    streakDays: vm.streak.current,
                    bestStreak: vm.streak.best,
                    averageSessionSeconds: vm.streak.averageSessionSeconds,
                    pomodoroService: pomodoroService,
                    soundService: pomodoroSoundService,
                    saveStatus: saveStatusService.status
                )
            } else {
                TopBarSessionTrayMinimal(
                    pomodoroService: pomodoroService,
                    soundService: pomodoroSoundService,
                    saveStatus: saveStatusService.status
                )
            }
        }
    }

    private var topBarContextTitle: String? {
        switch selection {
        case .learningIntelligence:
            return "Today"
        case .deckOrganizer:
            return "Decks"
        case .folder:
            return selectedFolder?.name ?? "Folder"
        case .deck:
            return selectedDeck?.name ?? "Deck"
        case .exam:
            return selectedExam?.title ?? "Exam"
        case .studyGuide:
            return selectedStudyGuide?.title ?? "Study Guide"
        case .course:
            return selectedCourse?.name ?? "Course"
        case .tag(let tag):
            return "#\(tag)"
        case .smart(let filter):
            return filter.title
        case .stats:
            return "Stats"
        case .settings:
            return "Settings"
        case .none:
            return nil
        }
    }

    private var breadcrumbs: [BreadcrumbCrumb] {
        switch selection {
        case .learningIntelligence:
            return [BreadcrumbCrumb(id: "today", title: "Today", sidebarItem: .learningIntelligence, icon: "sparkles")]
        case .deckOrganizer:
            return [BreadcrumbCrumb(id: "decks", title: "Decks", sidebarItem: .deckOrganizer, icon: "rectangle.stack")]
        case .stats:
            return [BreadcrumbCrumb(id: "stats", title: "Stats", sidebarItem: .stats, icon: "chart.bar.fill")]
        case .settings:
            return [BreadcrumbCrumb(id: "settings", title: "Settings", sidebarItem: .settings, icon: "gearshape.fill")]
        case .course(let id):
            let name = selectedCourse?.name ?? "Course"
            return [BreadcrumbCrumb(id: "course-\(id)", title: name, sidebarItem: .course(id), icon: "graduationcap.fill")]
        case .deck(let id):
            return buildDeckBreadcrumbs(deckId: id)
        case .folder(let id):
            return buildFolderBreadcrumbs(folderId: id)
        case .tag(let tag):
            return [BreadcrumbCrumb(id: "tag-\(tag)", title: "#\(tag)", sidebarItem: .tag(tag), icon: "tag.fill")]
        case .smart(let filter):
            return [BreadcrumbCrumb(id: "smart-\(filter.rawValue)", title: filter.title, sidebarItem: .smart(filter), icon: "line.3.horizontal.decrease.circle.fill")]
        case .exam(let id):
            let title = selectedExam?.title ?? "Exam"
            return [BreadcrumbCrumb(id: "exam-\(id)", title: title, sidebarItem: .exam(id), icon: "doc.text.fill")]
        case .studyGuide(let id):
            let title = selectedStudyGuide?.title ?? "Study Guide"
            return [BreadcrumbCrumb(id: "guide-\(id)", title: title, sidebarItem: .studyGuide(id), icon: "book.fill")]
        case .none:
            return []
        }
    }

    private func buildDeckBreadcrumbs(deckId: UUID) -> [BreadcrumbCrumb] {
        guard let deck = selectedDeck else {
            return [BreadcrumbCrumb(id: "deck-\(deckId)", title: "Deck", sidebarItem: .deck(deckId), icon: "rectangle.stack.fill")]
        }

        var path: [BreadcrumbCrumb] = []

        if let courseId = deck.courseId, let course = selectedCourse {
            path.append(BreadcrumbCrumb(id: "course-\(courseId)", title: course.name, sidebarItem: .course(courseId), icon: "graduationcap.fill"))
        }

        let deckCrumb = BreadcrumbCrumb(
            id: "deck-\(deck.id)",
            title: deck.name,
            sidebarItem: .deck(deck.id),
            icon: "rectangle.stack.fill"
        )

        if path.count >= 2 {
            let first = path[0]
            path = [first, BreadcrumbCrumb(id: "ellipsis", title: "...", sidebarItem: nil), deckCrumb]
        } else {
            path.append(deckCrumb)
        }

        return path
    }

    private func buildFolderBreadcrumbs(folderId: UUID) -> [BreadcrumbCrumb] {
        guard let folder = selectedFolder else {
            return [BreadcrumbCrumb(id: "folder-\(folderId)", title: "Folder", sidebarItem: .folder(folderId), icon: "folder.fill")]
        }

        var path: [BreadcrumbCrumb] = []

        if let courseId = folder.courseId, let course = selectedCourse {
            path.append(BreadcrumbCrumb(id: "course-\(courseId)", title: course.name, sidebarItem: .course(courseId), icon: "graduationcap.fill"))
        }

        let folderCrumb = BreadcrumbCrumb(
            id: "folder-\(folder.id)",
            title: folder.name,
            sidebarItem: .folder(folder.id),
            icon: "folder.fill"
        )

        if path.count >= 2 {
            let first = path[0]
            path = [first, BreadcrumbCrumb(id: "ellipsis", title: "...", sidebarItem: nil), folderCrumb]
        } else {
            path.append(folderCrumb)
        }

        return path
    }

    private func hideInspector() {
        withAnimation(DesignSystem.Animation.layout) {
            isInspectorVisible = false
        }
    }

    private func startStudySession(for filter: SmartFilter) {
        withAnimation(.easeInOut(duration: 0.2)) {
            activeSmartStudyFilter = filter
        }
    }

    @ViewBuilder
    private func smartFilterSession(for filter: SmartFilter) -> some View {
        switch filter {
        case .dueToday:
            StudySessionView(mode: .dueToday, onDismiss: endStudySession)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        case .new, .suspended:
            StudySessionUnavailableView(filter: filter, onClose: endStudySession)
        }
    }

    private func endStudySession() {
        withAnimation(.easeInOut(duration: 0.2)) {
            activeSmartStudyFilter = nil
        }
    }

    @MainActor
    private func presentQuickFind() {
        quickCommandViewModel.prepare()
        withAnimation(DesignSystem.Animation.layout) {
            isQuickFindPresented = true
        }
    }

    @MainActor
    private func dismissQuickFind() {
        withAnimation(DesignSystem.Animation.layout) {
            isQuickFindPresented = false
        }
    }

    private func openDeckEditor(deck: Deck? = nil, parentId: UUID? = nil, kind: Deck.Kind = .deck) {
        deckEditorTarget = deck
        deckEditorParentId = parentId ?? deck?.parentId
        deckEditorKind = kind
        isDeckEditorPresented = true
    }

    @MainActor
    private func createNewExam() async {
        let newExam = Exam(
            parentFolderId: nil,  // Created at root level
            title: "Untitled Exam",
            config: Exam.Config(),
            questions: []
        )
        do {
            try await storage.upsert(exam: newExam.toDTO())
            selection = .exam(newExam.id)
        } catch {
            // Error creating exam - silent for now, matches existing pattern
        }
    }
    
    @MainActor
    private func createNewStudyGuide() async {
        let newGuide = StudyGuide(
            parentFolderId: nil,  // Created at root level
            title: "Untitled Study Guide",
            markdownContent: ""
        )
        do {
            try await storage.upsert(studyGuide: newGuide.toDTO())
            selection = .studyGuide(newGuide.id)
        } catch {
            // Error creating study guide - silent for now, matches existing pattern
        }
    }

    @MainActor
    private func resetDeckEditorTarget() {
        deckEditorTarget = nil
        deckEditorParentId = nil
        deckEditorKind = .deck
    }

    private func prepareDeckDeletion() {
        guard let deck = selectedDeck else { return }
        deckPendingDeletion = deck
    }

    private func prepareDeckDeletion(for deck: Deck) {
        deckPendingDeletion = deck
    }

    private func deleteDeck(_ deck: Deck) async {
        await DeckService(storage: storage).delete(deckId: deck.id)
        await MainActor.run {
            if case .deck(deck.id) = selection {
                selection = nil
                selectedDeck = nil
            }
            workspaceSelection.clearCard()
            deckPendingDeletion = nil
        }
        await refreshSelection()
        await MainActor.run {
            showToast(title: "Deck Deleted", message: "\(deck.name) and its cards were removed.")
        }
    }

    private func mergeDeck(source: Deck, into destination: Deck) {
        guard source.id != destination.id else { return }
        Task {
            do {
                let service = DeckMergeService(storage: storage)
                let result = try await service.mergeDeck(withId: source.id, into: destination.id)
                await MainActor.run {
                    selection = .deck(destination.id)
                    showToast(
                        title: "Decks merged",
                        message: "Moved \(result.cardsMoved) cards into \(destination.name)."
                    )
                }
                await MainActor.run {
                    storeEvents.notify()
                }
            } catch DeckMergeService.MergeError.sourceNotFound {
                await MainActor.run { showError("Source deck no longer exists.") }
            } catch DeckMergeService.MergeError.destinationNotFound {
                await MainActor.run { showError("Destination deck no longer exists.") }
            } catch DeckMergeService.MergeError.sourceHasSubdecks {
                await MainActor.run { showError("Move or merge subdecks first before merging this deck.") }
            } catch {
                await MainActor.run { showError("Merge failed: \(error.localizedDescription)") }
            }
        }
    }

    private func saveDeckOrder(_ orderedIDs: [UUID]) {
        Task {
            do {
                var settings = try await DataController.shared.loadSettings()
                settings.deckSortOrder = orderedIDs
                await DataController.shared.save(settings: settings)
            } catch {
                await MainActor.run {
                    showError("Couldn't save deck order: \(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    private func handleDeckSaved(_ deck: Deck) async {
        isDeckEditorPresented = false
        selection = .deck(deck.id)
        deckEditorTarget = nil
        showToast(title: "Deck Saved", message: "\(deck.name) is ready to study.")
        await updateSelection(.deck(deck.id))
    }

    @MainActor
    private func handleQuickCommandSelection(_ result: QuickCommandResult) {
        dismissQuickFind()
        switch result.action {
        case .openDeck(let deckId):
            selection = .deck(deckId)
        case .openCard(let cardId, let deckId):
            workspaceSelection.prepareFocus(cardID: cardId)
            if let deckId = deckId {
                selection = .deck(deckId)
            } else {
                selection = .smart(.new)
            }
        case .filterTag(let tag):
            selection = .tag(tag)
        case .smartFilter(let filter):
            selection = .smart(filter)
        case .openStats:
            selection = .stats
        case .openSettings:
            selection = .settings
        }
    }

    private func shouldShowInspector(for selection: SidebarItem?) -> Bool {
        if workspaceSelection.focusedCard != nil {
            return true
        }
        guard let selection = selection else { return false }
        switch selection {
        case .learningIntelligence:
            return false
        case .deckOrganizer:
            return false
        case .folder:
            return false
        case .deck:
            return selectedDeck != nil
        case .exam:
            return selectedExam != nil
        case .studyGuide:
            return selectedStudyGuide != nil
        case .course:
            return false
        case .tag, .smart:
            return true
        case .stats, .settings:
            return false
        }
    }

    @MainActor
    private func adjustInspectorVisibility(for selection: SidebarItem?) {
        if workspaceSelection.focusedCard != nil {
            if !isInspectorVisible {
                isInspectorVisible = true
            }
            return
        }
        guard shouldShowInspector(for: selection) else {
            isInspectorVisible = false
            return
        }
        if !hasAutoOpenedInspector {
            isInspectorVisible = true
            hasAutoOpenedInspector = true
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateSelection(_ newSelection: SidebarItem?) async {
        guard let newSelection = newSelection else {
            await MainActor.run {
                selectedDeck = nil
                selectedFolder = nil
                selectedExam = nil
                selectedStudyGuide = nil
                selectedCourse = nil
                adjustInspectorVisibility(for: nil)
            }
            return
        }
        switch newSelection {
        case .folder(let id):
            let folder = await DeckService(storage: storage).deck(withId: id)
            await MainActor.run {
                selectedFolder = folder
                selectedDeck = nil
                selectedExam = nil
                selectedStudyGuide = nil
                selectedCourse = nil
                adjustInspectorVisibility(for: newSelection)
            }
        case .deck(let id):
            let deck = await DeckService(storage: storage).deck(withId: id)
            await MainActor.run {
                selectedDeck = deck
                selectedFolder = nil
                selectedExam = nil
                selectedStudyGuide = nil
                selectedCourse = nil
                adjustInspectorVisibility(for: newSelection)
            }
        case .exam(let id):
            let examDTO = try? await storage.exam(withId: id)
            await MainActor.run {
                selectedExam = examDTO?.toDomain()
                selectedDeck = nil
                selectedFolder = nil
                selectedStudyGuide = nil
                selectedCourse = nil
                adjustInspectorVisibility(for: newSelection)
            }
        case .studyGuide(let id):
            let guideDTO = try? await storage.studyGuide(withId: id)
            await MainActor.run {
                selectedStudyGuide = guideDTO?.toDomain()
                selectedDeck = nil
                selectedFolder = nil
                selectedExam = nil
                selectedCourse = nil
                adjustInspectorVisibility(for: newSelection)
            }
        case .course(let id):
            let courseDTO = try? await storage.course(withId: id)
            await MainActor.run {
                selectedCourse = courseDTO?.toDomain()
                selectedDeck = nil
                selectedFolder = nil
                selectedExam = nil
                selectedStudyGuide = nil
                adjustInspectorVisibility(for: newSelection)
            }
        default:
            await MainActor.run {
                selectedDeck = nil
                selectedFolder = nil
                selectedExam = nil
                selectedStudyGuide = nil
                selectedCourse = nil
                adjustInspectorVisibility(for: newSelection)
            }
        }
    }

    private func refreshSelection() async {
        if let current = selection {
            await updateSelection(current)
        } else {
            let fallback = await defaultSelection()
            await MainActor.run { selection = fallback }
            await updateSelection(fallback)
        }
    }

    private func defaultSelection() async -> SidebarItem? {
        return .learningIntelligence
    }

    private func handleFileImport(result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Task {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let values = try? url.resourceValues(forKeys: [.contentTypeKey])
                    let source = ImportSource(
                        data: data,
                        filename: url.lastPathComponent,
                        contentType: values?.contentType
                    )
                    let coordinator = await MainActor.run { DeckImportCoordinator(storage: storage) }
                    let resolved = try await coordinator.loadPreview(from: source)
                    let targets = await loadMergeTargets()
                    await MainActor.run {
                        let plan = defaultMergePlan(for: resolved.preview, targets: targets, context: importContext)
                        importTargets = targets
                        importPlan = plan
                        importPreview = resolved.preview
                        cachedImportSource = source
                        cachedImportDescriptorID = resolved.descriptorID
                    }
                } catch let error as ImportErrorDetail {
                    await MainActor.run { showError(error.message) }
                } catch {
                    await MainActor.run { showError("Could not read file: \(error.localizedDescription)") }
                }
            }
        case .failure(let error):
            if let cocoaError = error as? CocoaError, cocoaError.code == .userCancelled {
                importContext = .workspace
                return
            }
            importContext = .workspace
            showError("Import failed: \(error.localizedDescription)")
        }
    }

    private func loadMergeTargets() async -> [DeckMergeTarget] {
        let decks = await DeckService(storage: storage).allDecks(includeArchived: true)
        let hierarchy = DeckHierarchy(decks: decks)
        let sorted = decks.sorted { lhs, rhs in
            hierarchy.displayPath(of: lhs.id).localizedCaseInsensitiveCompare(hierarchy.displayPath(of: rhs.id)) == .orderedAscending
        }
        return sorted.map {
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

    private func defaultMergePlan(
        for preview: ImportPreview,
        targets: [DeckMergeTarget],
        context: ImportInvocationContext
    ) -> DeckMergePlan {
        var plan = DeckMergePlan()
        if preview.decks.count == 1,
           case .deck(let targetID) = context,
           let target = targets.first(where: { $0.id == targetID }) {
            plan.setAssignment(.init(destination: .existing(target)), for: preview.decks[0].token)
        }
        return plan
    }

    private func performImport() {
        guard importPreview != nil else { return }
        if let preview = importPreview {
            let subtitle = "\(preview.deckCount) \(preview.deckCount == 1 ? "deck" : "decks") • \(preview.cardCount) \(preview.cardCount == 1 ? "card" : "cards")"
            withAnimation(DesignSystem.Animation.smooth) {
                importOverlayState = ImportOperationOverlayState(
                    title: "Importing…",
                    subtitle: subtitle,
                    phase: .importing(progress: nil)
                )
            }
        }
        Task {
            do {
                guard let descriptorID = cachedImportDescriptorID, let source = cachedImportSource else {
                    await MainActor.run { showError("Original file data no longer available.") }
                    return
                }
                let plan = await MainActor.run { importPlan }
                let coordinator = DeckImportCoordinator(storage: storage)
                let result = try await coordinator.performImport(using: descriptorID, source: source, mergePlan: plan)
                await MainActor.run {
                    importResult = result
                    showingImportSummary = true
                    if let firstDeck = importPreview?.decks.first {
                        let assignment = plan.assignment(for: firstDeck.token)
                        switch assignment.destination {
                        case .createNew:
                            selection = .deck(firstDeck.id)
                        case .existing(let target):
                            selection = .deck(target.id)
                        }
                    }
                    showToast(title: "Import complete", message: "Added \(result.cardsInserted) cards, updated \(result.cardsUpdated).")
                    importPlan = .empty
                    importTargets = []
                    importContext = .workspace
                    withAnimation(DesignSystem.Animation.smooth) {
                        importOverlayState = ImportOperationOverlayState(
                            title: "Import complete",
                            subtitle: "Added \(result.cardsInserted) cards • Updated \(result.cardsUpdated)",
                            phase: .success
                        )
                    }
                }
                await refreshSelection()
                try? await Task.sleep(nanoseconds: 650_000_000)
                await MainActor.run {
                    resetImportPreview()
                }
            } catch let error as ImportErrorDetail {
                await MainActor.run {
                    withAnimation(DesignSystem.Animation.smooth) {
                        importOverlayState = ImportOperationOverlayState(
                            title: "Import failed",
                            subtitle: error.message,
                            phase: .failure
                        )
                    }
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await MainActor.run {
                    resetImportPreview()
                    showError(error.message)
                }
            } catch {
                await MainActor.run {
                    withAnimation(DesignSystem.Animation.smooth) {
                        importOverlayState = ImportOperationOverlayState(
                            title: "Import failed",
                            subtitle: error.localizedDescription,
                            phase: .failure
                        )
                    }
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await MainActor.run {
                    resetImportPreview()
                    showError("Import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func prepareExport() {
        Task {
            let decks = await decksForExport()
            await MainActor.run {
                pendingExportDecks = decks
                if decks.isEmpty {
                    showError("No decks available to export.")
                } else {
                    exportFormatDialogPresented = true
                }
            }
        }
    }

    private func performExport(for decks: [Deck], format: DeckExportFormat) {
        Task {
            do {
                let exporter = DeckExporter(storage: storage)
                let request = try await exporter.makeExportRequest(for: decks, format: format)
                await MainActor.run {
                    exportDocument = DeckExportDocument(request: request)
                    exportContentType = format.contentType
                    exportFilename = request.suggestedFilename
                    fileExporterPresented = true
                    showToast(title: "Export ready", message: exportToastMessage(for: decks, format: format))
                }
            } catch DeckExportError.noDecks {
                await MainActor.run { showError("No decks available to export.") }
            } catch DeckExportError.encodingFailed {
                await MainActor.run { showError("Export failed: Unable to encode file data.") }
            } catch {
                await MainActor.run { showError("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    private func decksForExport() async -> [Deck] {
        let service = DeckService(storage: storage)
        switch selection {
        case .deck(let id):
            if let deck = await service.deck(withId: id) { return [deck] }
            return []
        default:
            let decks = await service.allDecks()
            return decks.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func exportToastMessage(for decks: [Deck], format: DeckExportFormat) -> String {
        if decks.count == 1, let deck = decks.first {
            return "Exported \(deck.name) as \(format.displayName)"
        }
        return "Exporting \(decks.count) deck(s) as \(format.displayName)"
    }

    private func exportDialogTitle(for decks: [Deck]) -> String {
        if decks.count == 1, let deck = decks.first {
            return "Export \(deck.name)"
        }
        return "Export \(decks.count) decks"
    }

    private func exportDialogMessage(for decks: [Deck]) -> String {
        if decks.count == 1 {
            return "Choose a format to download this deck."
        }
        return "Choose a format to download your deck collection."
    }

    private func archiveDeck(_ deck: Deck) {
        Task {
            await DeckService(storage: storage).setArchiveStatus(deckId: deck.id, isArchived: true)
            await MainActor.run {
                showToast(title: "Deck archived", message: "\(deck.name) moved to archive.")
            }
        }
    }

    private func unarchiveDeck(_ deck: Deck) {
        Task {
            await DeckService(storage: storage).setArchiveStatus(deckId: deck.id, isArchived: false)
            await MainActor.run {
                showToast(title: "Deck restored", message: "\(deck.name) is active again.")
            }
        }
    }

    private func exportDeck(_ deck: Deck) {
        Task { @MainActor in
            pendingExportDecks = [deck]
            exportFormatDialogPresented = true
        }
    }

    @MainActor
    private func showError(_ message: String) {
        errorMessage = message
        showingErrorAlert = true
    }

    @MainActor
    private func showToast(title: String, message: String) {
        let pending = ToastData(title: title, message: message)
        toast = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation {
                if toast == pending {
                    toast = nil
                }
            }
        }
    }
}

private struct WorkspaceInspector: View {
    @Environment(\.storage) private var storage
    @EnvironmentObject private var workspaceSelection: WorkspaceSelection
    @EnvironmentObject private var storeEvents: StoreEvents

    let selection: SidebarItem?
    let deck: Deck?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader

            Group {
                if let card = workspaceSelection.focusedCard {
                    CardDetailInspector(
                        card: card,
                        onEdit: {
                            // Handle edit action
                        },
                        onDelete: {
                            Task {
                                await CardService(storage: storage).delete(cardId: card.id)
                                workspaceSelection.clearCard()
                            }
                        },
                        onToggleSuspend: {
                            Task {
                                var updated = card
                                updated.isSuspended.toggle()
                                await CardService(storage: storage).upsert(card: updated)
                            }
                        }
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                            selectionContent
                        }
                        .padding(DesignSystem.Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private var inspectorHeader: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DesignSystem.Colors.subtleOverlay)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide inspector")
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.top, DesignSystem.Spacing.md)
            .padding(.bottom, DesignSystem.Spacing.sm)
        }
    }

    @ViewBuilder
    private var selectionContent: some View {
        switch selection {
        case .learningIntelligence:
            EmptyView()
        case .deckOrganizer:
            InspectorBlock(title: "Deck Organizer") {
                Text("Drag decks to reorder, drop onto a deck to create subdecks, or switch to merge mode to combine decks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .folder:
            InspectorBlock(title: "Folder") {
                Text("Browse and organize your decks and subfolders. Create new decks or folders using the actions above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .deck:
            deckSection
        case .exam:
            InspectorBlock(title: "Exam") {
                Text("View and edit multiple-choice exam questions. Inspector tools for timing and scoring insights coming soon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .studyGuide:
            InspectorBlock(title: "Study Guide") {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Use Edit / Preview / Split modes, drag files into the editor, and run inline AI copilot suggestions with per-change accept/reject.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Grounding is local-only: guide markdown, selected text, related deck/card metadata, and attached files.")
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .course:
            InspectorBlock(title: "Course") {
                Text("View course topics, materials, and linked study content. Coverage tracking and study planning tools coming soon.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .tag(let tag):
            tagSection(tag)
        case .smart(let filter):
            smartSection(filter)
        case .stats:
            InspectorBlock(title: "Workspace stats") {
                Text("Dive into the stats canvas to compare historical performance, pacing, and streaks across decks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .settings:
            InspectorBlock(title: "Preferences") {
                Text("Settings now live in the right rail as you edit forms. Upcoming builds will surface contextual help, defaults, and reset actions here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .none:
            if workspaceSelection.focusedCard == nil {
                placeholder
            }
        }
    }

    @ViewBuilder
    private var deckSection: some View {
        if let deck = deck {
            DeckOverviewInspector(deck: deck, storage: storage)
        } else if workspaceSelection.focusedCard == nil {
            placeholder
        }
    }

    private func tagSection(_ tag: String) -> some View {
        InspectorBlock(title: "Tag focus") {
            Text("Reviewing cards tagged with #\(tag). Pair this view with the command palette to queue quick clean-up passes.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func smartSection(_ filter: SmartFilter) -> some View {
        InspectorBlock(title: filter.title) {
            Text(filterInspectorMessage(for: filter))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var placeholder: some View {
        InspectorBlock(title: "Inspector") {
            Text("Select a deck or card to surface metadata, scheduling stats, and quick actions.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func filterInspectorMessage(for filter: SmartFilter) -> String {
        switch filter {
        case .dueToday:
            return "Stay on pace by clearing cards scheduled today. Inspector insights highlight streaks and upcoming hotspots."
        case .new:
            return "Use this filter to seed fresh material. We'll surface creation templates and drafting tips as they become available."
        case .suspended:
            return "Review why cards were paused and when to safely reintroduce them. Future updates will suggest reinstatement windows."
        }
    }

    private struct CardInspectorPanel: View {
        @Environment(\.storage) private var storage
        @EnvironmentObject private var storeEvents: StoreEvents

        let card: Card
        let deck: Deck?

        @State private var recentLogs: [ReviewLog] = []
        @State private var showingEditor = false

        private static let relativeFormatter: RelativeDateTimeFormatter = {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter
        }()

        var body: some View {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                InspectorBlock(title: "Card") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        contentSection(title: "Prompt", value: card.displayPrompt)
                        Divider()
                        if card.kind == .cloze, let source = card.clozeSource {
                            contentSection(title: "Cloze Source", value: source)
                        } else if card.kind == .multipleChoice {
                            multipleChoiceSection()
                            if !card.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Divider()
                                contentSection(title: "Explanation", value: card.back)
                            }
                        } else {
                            contentSection(title: "Answer", value: card.displayAnswer)
                        }
                        if let deck = deck {
                            Divider()
                            Label(deck.name, systemImage: "rectangle.stack")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                InspectorBlock(title: "Scheduling") {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                        scheduleRow(label: "Queue", value: card.srs.queue.rawValue.capitalized)
                        scheduleRow(label: "Next Review", value: dueText)
                        scheduleRow(label: "Predicted Recall", value: String(format: "%.0f%%", card.srs.predictedRecallAtScheduled(retentionTarget: AppSettingsDefaults.retentionTarget) * 100))
                        scheduleRow(label: "Stability", value: String(format: "%.1f days", card.srs.stability))
                        scheduleRow(label: "Difficulty", value: String(format: "%.1f", card.srs.difficulty))
                        scheduleRow(label: "FSRS Reps", value: "\(card.srs.fsrsReps)")
                        scheduleRow(label: "Lapses", value: "\(card.srs.lapses)")
                    }
                }

                if !card.tags.isEmpty {
                    InspectorBlock(title: "Tags") {
                        Text(card.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                InspectorBlock(title: "Recent activity") {
                    if recentLogs.isEmpty {
                        Text("No reviews logged yet. First study session will appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            ForEach(recentLogs) { log in
                                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                                    Text(log.timestamp, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(log.timestamp, style: .time)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("Grade \(log.grade)")
                                        .font(.caption)
                                    Text("→ \(log.nextInterval)d")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }

                InspectorBlock(title: "Actions") {
                    Button {
                        showingEditor = true
                    } label: {
                        Label("Open Editor", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .task(id: card.id) { await loadLogs(for: card.id) }
            .onReceive(storeEvents.$tick) { _ in Task { await loadLogs(for: card.id) } }
            .sheet(isPresented: $showingEditor) {
                CardEditorView(card: card, storage: storage)
                    .frame(minWidth: 640, minHeight: 460)
            }
        }

        private func contentSection(title: String, value: String) -> some View {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MarkdownText(value)
                    .font(.body)
            }
        }

        @ViewBuilder
        private func multipleChoiceSection() -> some View {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("CHOICES")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(Array(card.choices.enumerated()), id: \.offset) { index, choice in
                        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MarkdownText(choice.isEmpty ? "—" : choice)
                                .font(.body)
                            if index == card.correctChoiceIndex {
                                Text("Correct")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }

        private func scheduleRow(label: String, value: String) -> some View {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.callout)
            }
        }

        private var dueText: String {
            CardInspectorPanel.relativeFormatter.localizedString(for: card.srs.dueDate, relativeTo: Date())
        }

        private func loadLogs(for cardId: UUID) async {
            let allLogs = await ReviewLogService(storage: storage).recentLogs(limit: 200)
            let filtered = allLogs
                .filter { $0.cardId == cardId }
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(5)
            await MainActor.run {
                recentLogs = Array(filtered)
            }
        }
    }
}

private struct InspectorBlock<Content: View>: View {
    let title: String
    private let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            content
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.window.opacity(0.75))
        )
    }
}


// MARK: - Deck Overview Inspector

private struct DeckOverviewInspector: View {
    let deck: Deck
    let storage: Storage
    
    @State private var deckStats: DeckOverviewStats = .empty
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            // Deck header with name + last updated
            deckHeader
            
            // Stats grid - key metrics at a glance
            statsGrid
            
            // Mastery visualization
            masterySection
            
            // Queue breakdown
            queueBreakdown
            
            // Deck metadata
            metadataSection
        }
        .task(id: deck.id) { await loadStats() }
    }
    
    // MARK: - Header Section
    
    private var deckHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.subtleOverlay)
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                }
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(deck.name)
                        .font(DesignSystem.Typography.bodyMedium)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                        .lineLimit(2)
                    
                    Text("Updated \(deck.updatedAt, style: .relative)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.tertiaryText)
                }
            }
            
            if let note = deck.note, !note.isEmpty {
                Text(note)
                    .font(DesignSystem.Typography.small)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .lineLimit(3)
                    .padding(.top, DesignSystem.Spacing.xs)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.window.opacity(0.75))
        )
    }
    
    // MARK: - Stats Grid
    
    private var statsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)
        ], spacing: DesignSystem.Spacing.sm) {
            StatCell(
                value: "\(deckStats.totalCards)",
                label: "Total",
                icon: "rectangle.stack"
            )
            
            StatCell(
                value: "\(deckStats.dueToday)",
                label: "Due today",
                icon: "calendar.badge.clock",
                isHighlighted: deckStats.dueToday > 0
            )
            
            StatCell(
                value: "\(deckStats.newCards)",
                label: "New",
                icon: "sparkles"
            )
            
            StatCell(
                value: formatPercent(deckStats.averageMastery),
                label: "Mastery",
                icon: "chart.line.uptrend.xyaxis"
            )
        }
    }
    
    // MARK: - Mastery Section
    
    private var masterySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                Text("LEARNING PROGRESS")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.tertiaryText)
                    .tracking(0.5)
            }
            
            // Mastery bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(DesignSystem.Colors.subtleOverlay)
                    
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(masteryGradient)
                        .frame(width: geo.size.width * CGFloat(deckStats.averageMastery))
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: deckStats.averageMastery)
                }
            }
            .frame(height: 8)
            
            // Legend
            HStack(spacing: DesignSystem.Spacing.md) {
                LegendDot(color: DesignSystem.Colors.primaryText.opacity(0.8), label: "Mastered", count: deckStats.masteredCards)
                LegendDot(color: DesignSystem.Colors.secondaryText, label: "Learning", count: deckStats.learningCards)
                LegendDot(color: DesignSystem.Colors.tertiaryText, label: "New", count: deckStats.newCards)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.window.opacity(0.75))
        )
    }
    
    // MARK: - Queue Breakdown
    
    private var queueBreakdown: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                Text("QUEUE STATUS")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.tertiaryText)
                    .tracking(0.5)
            }
            
            VStack(spacing: DesignSystem.Spacing.xs) {
                QueueRow(label: "Due today", count: deckStats.dueToday, icon: "clock.badge.exclamationmark", isUrgent: true)
                QueueRow(label: "Due this week", count: deckStats.dueThisWeek, icon: "calendar")
                QueueRow(label: "Suspended", count: deckStats.suspendedCards, icon: "pause.circle")
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.window.opacity(0.75))
        )
    }
    
    // MARK: - Metadata Section
    
    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                Text("DETAILS")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.tertiaryText)
                    .tracking(0.5)
            }
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                MetadataRow(label: "Created", value: deck.createdAt.formatted(date: .abbreviated, time: .omitted))
                MetadataRow(label: "Last studied", value: deckStats.lastStudied.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Never")
                if deck.dueDate != nil {
                    MetadataRow(label: "Due date", value: deck.dueDate!.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.window.opacity(0.75))
        )
    }
    
    // MARK: - Helpers
    
    private var masteryGradient: LinearGradient {
        LinearGradient(
            colors: [DesignSystem.Colors.primaryText.opacity(0.5), DesignSystem.Colors.primaryText.opacity(0.7)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
    
    private func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
    
    private func loadStats() async {
        isLoading = true
        let cardService = CardService(storage: storage)
        let logService = ReviewLogService(storage: storage)
        
        let cards = await cardService.allCards().filter { $0.deckId == deck.id }
        let logs = await logService.recentLogs(limit: 500).filter { log in
            cards.contains { $0.id == log.cardId }
        }
        
        let now = Date()
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: 7, to: startOfToday)!
        
        let dueToday = cards.filter { !$0.isSuspended && $0.srs.dueDate <= now }.count
        let dueThisWeek = cards.filter { !$0.isSuspended && $0.srs.dueDate <= startOfWeek && $0.srs.dueDate > now }.count
        let newCards = cards.filter { $0.srs.queue == .new }.count
        let suspendedCards = cards.filter { $0.isSuspended }.count
        let learningCards = cards.filter { $0.srs.queue == .learning || $0.srs.queue == .relearn }.count
        let masteredCards = cards.filter { $0.srs.queue == .review && $0.srs.stability >= 30 }.count
        
        let totalMastery = cards.isEmpty ? 0 : cards.reduce(0.0) { $0 + min($1.srs.stability / 90.0, 1.0) } / Double(cards.count)
        let lastStudied = logs.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        
        await MainActor.run {
            deckStats = DeckOverviewStats(
                totalCards: cards.count,
                dueToday: dueToday,
                dueThisWeek: dueThisWeek,
                newCards: newCards,
                learningCards: learningCards,
                masteredCards: masteredCards,
                suspendedCards: suspendedCards,
                averageMastery: totalMastery,
                lastStudied: lastStudied
            )
            isLoading = false
        }
    }
}

// MARK: - Deck Overview Stats Model

private struct DeckOverviewStats {
    let totalCards: Int
    let dueToday: Int
    let dueThisWeek: Int
    let newCards: Int
    let learningCards: Int
    let masteredCards: Int
    let suspendedCards: Int
    let averageMastery: Double
    let lastStudied: Date?
    
    static let empty = DeckOverviewStats(
        totalCards: 0,
        dueToday: 0,
        dueThisWeek: 0,
        newCards: 0,
        learningCards: 0,
        masteredCards: 0,
        suspendedCards: 0,
        averageMastery: 0,
        lastStudied: nil
    )
}

// MARK: - Inspector Sub-Components

private struct StatCell: View {
    let value: String
    let label: String
    let icon: String
    var isHighlighted: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isHighlighted ? DesignSystem.Colors.primaryText : DesignSystem.Colors.tertiaryText)
                Text(value)
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                    .fontWeight(isHighlighted ? .semibold : .regular)
            }
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.tertiaryText)
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.window.opacity(0.5))
        )
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String
    let count: Int
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
        }
    }
}

private struct QueueRow: View {
    let label: String
    let count: Int
    let icon: String
    var isUrgent: Bool = false
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.tertiaryText)
                .frame(width: 16)
            
            Text(label)
                .font(DesignSystem.Typography.small)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
            
            Spacer()
            
            Text("\(count)")
                .font(DesignSystem.Typography.smallMedium)
                .foregroundStyle(DesignSystem.Colors.primaryText)
                .fontWeight(isUrgent && count > 0 ? .semibold : .regular)
        }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(DesignSystem.Typography.small)
                .foregroundStyle(DesignSystem.Colors.tertiaryText)
            Spacer()
            Text(value)
                .font(DesignSystem.Typography.small)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .lineLimit(1)
        }
    }
}


// MARK: - Smart Filter Canvas

private struct StudySessionUnavailableView: View {
    let filter: SmartFilter
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            Text("Study session is not ready")
                .font(DesignSystem.Typography.heading)
                .foregroundStyle(.primary)
            Text(detailMessage)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to overview") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: 420)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .fill(DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .stroke(DesignSystem.Colors.separator, lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var detailMessage: String {
        switch filter {
        case .new:
            return "We're building a tailored onboarding flow for brand-new cards. Check back soon to seed fresh content."
        case .suspended:
            return "Reactivation guidance is on the roadmap. Review the suspended cards list for now."
        case .dueToday:
            return "This session type is temporarily unavailable."
        }
    }
}

private struct SmartFilterCanvas: View {
    let filter: SmartFilter
    let storage: Storage
    let onStudy: () -> Void
    
    @State private var stats: FilterStats?
    @State private var isLoading = true
    
    var body: some View {
        WorkspaceCanvas { _ in
            // Hero section with prominent CTA
            CanvasBlock(title: filter.title, subtitle: smartFilterSubtitle(for: filter)) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    if let stats = stats {
                        filterStatsSection(stats)
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    
                    if filter == .dueToday {
                        HStack(spacing: DesignSystem.Spacing.md) {
                            Button {
                                onStudy()
                            } label: {
                                HStack(spacing: DesignSystem.Spacing.sm) {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                    Text("Start Study Session")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, DesignSystem.Spacing.md)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut("s", modifiers: .command)
                            .help("Begin studying due cards (⌘S)")
                            
                            if let stats = stats, stats.upcomingCount > 0 {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(stats.upcomingCount) upcoming")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Next 7 days")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, DesignSystem.Spacing.md)
                                .frame(minWidth: 100)
                            }
                        }
                    }
                    
                    Text(filterInspectorMessage(for: filter))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Enhanced cards view with filters and sort
            CanvasBlock(title: "Cards") {
                EnhancedCardTableView(filter: .smart(filter), storage: storage)
            }
        }
        .task {
            await loadStats()
        }
    }
    
    @ViewBuilder
    private func filterStatsSection(_ stats: FilterStats) -> some View {
        HStack(spacing: DesignSystem.Spacing.xl) {
            StatPill(
                label: "Total",
                value: "\(stats.totalCount)",
                icon: "rectangle.stack",
                color: .blue
            )
            .help("Total cards in this filter")
            
            if stats.suspendedCount > 0 {
                StatPill(
                    label: "Suspended",
                    value: "\(stats.suspendedCount)",
                    icon: "pause.circle",
                    color: .orange
                )
                .help("Cards currently suspended from review")
            }
            
            if filter == .dueToday && stats.overdueCount > 0 {
                StatPill(
                    label: "Overdue",
                    value: "\(stats.overdueCount)",
                    icon: "exclamationmark.triangle",
                    color: .red
                )
                .help("Cards that were due in previous days")
            }
        }
    }
    
    private func smartFilterSubtitle(for filter: SmartFilter) -> String {
        filter.subtitle
    }
    
    private func filterInspectorMessage(for filter: SmartFilter) -> String {
        switch filter {
        case .dueToday:
            return "Stay on pace by clearing cards scheduled today. Inspector insights highlight streaks and upcoming hotspots."
        case .new:
            return "Use this filter to seed fresh material. We'll surface creation templates and drafting tips as they become available."
        case .suspended:
            return "Review why cards were paused and when to safely reintroduce them. Future updates will suggest reinstatement windows."
        }
    }
    
    private func loadStats() async {
        isLoading = true
        let service = CardService(storage: storage)
        let cards = await service.allCards()
        
        let filtered: [Card]
        switch filter {
        case .dueToday:
            filtered = cards.filter { !$0.isSuspended && $0.srs.dueDate <= Date() }
        case .new:
            filtered = cards.filter { $0.srs.queue == .new }
        case .suspended:
            filtered = cards.filter { $0.isSuspended }
        }
        
        let suspended = filtered.filter { $0.isSuspended }.count
        let overdue = filter == .dueToday ? filtered.filter { 
            Calendar.current.isDate($0.srs.dueDate, lessThan: Calendar.current.startOfDay(for: Date()))
        }.count : 0
        
        let upcoming = filter == .dueToday ? cards.filter {
            !$0.isSuspended && 
            $0.srs.dueDate > Date() && 
            $0.srs.dueDate <= Calendar.current.date(byAdding: .day, value: 7, to: Date())!
        }.count : 0
        
        await MainActor.run {
            stats = FilterStats(
                totalCount: filtered.count,
                suspendedCount: suspended,
                overdueCount: overdue,
                upcomingCount: upcoming
            )
            isLoading = false
        }
    }
}

private struct FilterStats {
    let totalCount: Int
    let suspendedCount: Int
    let overdueCount: Int
    let upcomingCount: Int
}

// MARK: - Tag Canvas

private struct TagDetailCanvas: View {
    let tag: String
    let storage: Storage
    
    @State private var cardCount: Int = 0
    
    var body: some View {
        WorkspaceCanvas { _ in
            CanvasBlock(title: "#\(tag)", subtitle: "Cards tagged with \(tag)") {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        StatPill(
                            label: "Cards",
                            value: "\(cardCount)",
                            icon: "tag",
                            color: .purple
                        )
                        .help("Total cards with this tag")
                    }
                    
                    Text("Select a card from the table to explore its scheduling details and history in the inspector.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            
            CanvasBlock(title: "Cards") {
                EnhancedCardTableView(filter: .tag(tag), storage: storage)
            }
        }
        .task {
            await loadCardCount()
        }
    }
    
    private func loadCardCount() async {
        let service = CardService(storage: storage)
        let cards = await service.allCards()
        let filtered = cards.filter { $0.tags.contains(tag) }
        await MainActor.run {
            cardCount = filtered.count
        }
    }
}

// MARK: - Stat Pill Component

private struct StatPill: View {
    let label: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Enhanced Card Table

private struct EnhancedCardTableView: View {
    let filter: CardFilter
    let storage: Storage
    
    @EnvironmentObject private var workspaceSelection: WorkspaceSelection
    @EnvironmentObject private var storeEvents: StoreEvents
    
    @State private var cards: [Card] = []
    @State private var sortOrder: CardSortOrder = .dueDate
    @State private var searchText = ""
    @State private var showSuspended = true
    
    enum CardFilter {
        case tag(String)
        case smart(SmartFilter)
    }
    
    enum CardSortOrder: String, CaseIterable {
        case dueDate = "Due Date"
        case created = "Created"
        case updated = "Updated"
        case interval = "Interval"
        case stability = "Stability"

        var icon: String {
            switch self {
            case .dueDate: return "calendar"
            case .created: return "calendar.badge.plus"
            case .updated: return "clock.arrow.circlepath"
            case .interval: return "arrow.left.arrow.right"
            case .stability: return "chart.bar"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Control bar
            HStack(spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    TextField("Filter cards...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                }
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.window.opacity(0.5))
                )
                .frame(maxWidth: 280)
                
                Toggle(isOn: $showSuspended) {
                    Label("Show Suspended", systemImage: "pause.circle")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Toggle visibility of suspended cards")
                
                Spacer()
                
                Menu {
                    ForEach(CardSortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            Label(order.rawValue, systemImage: order.icon)
                        }
                    }
                } label: {
                    Label("Sort: \(sortOrder.rawValue)", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Change sort order")
                
                Text("\(filteredCards.count) cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(DesignSystem.Spacing.md)
            
            Divider()
            
            // Table
            Table(filteredCards) {
                TableColumn("Card") { card in
                    CardRowContent(card: card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 200, ideal: 400)
                
                TableColumn("Status") { card in
                    CardStatusBadge(card: card)
                }
                .width(min: 100, ideal: 120)
                
                TableColumn("Due") { card in
                    DueDateLabel(date: card.srs.dueDate)
                }
                .width(min: 100, ideal: 120)
                
                TableColumn("Interval") { card in
                    Text("\(card.srs.interval)d")
                        .font(.callout.monospacedDigit())
                }
                .width(min: 60, ideal: 80)

                TableColumn("Predicted") { card in
                    let predicted = card.srs.predictedRecallAtScheduled(retentionTarget: AppSettingsDefaults.retentionTarget)
                    Text(String(format: "%.0f%%", predicted * 100))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(predicted < AppSettingsDefaults.retentionTarget ? Color.orange : .secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Stability") { card in
                    Text(String(format: "%.1f", card.srs.stability))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Difficulty") { card in
                    Text(String(format: "%.1f", card.srs.difficulty))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)

                TableColumn("Reps") { card in
                    Text("\(card.srs.fsrsReps)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60)
            }
            .onTapGesture { coordinate in
                // Table handles row selection
            }
        }
        .task {
            await loadCards()
        }
        .onChange(of: storeEvents.tick) { _, _ in
            Task { await loadCards() }
        }
        .onChange(of: showSuspended) { _, _ in
            // Trigger filter refresh
        }
    }
    
    private var filteredCards: [Card] {
        var result = cards
        
        if !showSuspended {
            result = result.filter { !$0.isSuspended }
        }
        
        if !searchText.isEmpty {
            result = result.filter { card in
                card.front.localizedCaseInsensitiveContains(searchText) ||
                card.back.localizedCaseInsensitiveContains(searchText) ||
                card.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        
        return result.sorted { card1, card2 in
            switch sortOrder {
            case .dueDate:
                return card1.srs.dueDate < card2.srs.dueDate
            case .created:
                return card1.createdAt > card2.createdAt
            case .updated:
                return card1.updatedAt > card2.updatedAt
            case .interval:
                return card1.srs.interval > card2.srs.interval
            case .stability:
                return card1.srs.stability > card2.srs.stability
            }
        }
    }
    
    private func loadCards() async {
        let service = CardService(storage: storage)
        let allCards = await service.allCards()
        
        let filtered: [Card]
        switch filter {
        case .tag(let tag):
            filtered = allCards.filter { $0.tags.contains(tag) }
        case .smart(let smartFilter):
            switch smartFilter {
            case .dueToday:
                filtered = allCards.filter { !$0.isSuspended && $0.srs.dueDate <= Date() }
            case .new:
                filtered = allCards.filter { $0.srs.queue == .new }
            case .suspended:
                filtered = allCards.filter { $0.isSuspended }
            }
        }
        
        await MainActor.run {
            cards = filtered
        }
    }
}

private struct CardRowContent: View {
    let card: Card
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.displayPrompt)
                .font(.callout)
                .lineLimit(2)
                .help(card.displayPrompt)
            
            if !card.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(card.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if card.tags.count > 3 {
                        Text("+\(card.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct CardStatusBadge: View {
    let card: Card
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
        }
        .help(statusTooltip)
    }
    
    private var statusColor: Color {
        if card.isSuspended {
            return .orange
        }
        switch card.srs.queue {
        case .new:
            return .blue
        case .learning:
            return .purple
        case .review:
            if card.srs.dueDate <= Date() {
                return .green
            }
            return .gray
        case .relearn:
            return .yellow
        }
    }
    
    private var statusText: String {
        if card.isSuspended {
            return "Suspended"
        }
        switch card.srs.queue {
        case .new:
            return "New"
        case .learning:
            return "Learning"
        case .review:
            return card.srs.dueDate <= Date() ? "Due" : "Scheduled"
        case .relearn:
            return "Relearning"
        }
    }
    
    private var statusTooltip: String {
        if card.isSuspended {
            return "This card is suspended and won't appear in study sessions"
        }
        switch card.srs.queue {
        case .new:
            return "Not yet studied"
        case .learning:
            return "Currently being learned with short intervals"
        case .review:
            return card.srs.dueDate <= Date() ? "Ready for review" : "Scheduled for future review"
        case .relearn:
            return "Being relearned after a lapse"
        }
    }
}

private struct DueDateLabel: View {
    let date: Date
    
    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    
    var body: some View {
        Text(relativeText)
            .font(.callout.monospacedDigit())
            .foregroundStyle(isOverdue ? .red : (isDueToday ? .green : .secondary))
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }
    
    private var relativeText: String {
        DueDateLabel.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
    
    private var isOverdue: Bool {
        date < Calendar.current.startOfDay(for: Date())
    }
    
    private var isDueToday: Bool {
        Calendar.current.isDateInToday(date)
    }
}


private extension Calendar {
    func isDate(_ date1: Date, lessThan date2: Date) -> Bool {
        return date1 < date2
    }
}

private struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ToastData: Equatable {
    let title: String
    let message: String
}

private enum ImportInvocationContext: Equatable {
    case workspace
    case deck(UUID)

    var preferredDeckID: UUID? {
        switch self {
        case .workspace:
            return nil
        case .deck(let id):
            return id
        }
    }
}

#if DEBUG
#Preview("RootView") {
    RevuPreviewHost { _ in
        RootView()
            .frame(width: 1200, height: 820)
    }
}
#endif
