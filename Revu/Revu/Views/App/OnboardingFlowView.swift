import SwiftUI

struct OnboardingFlowView: View {
    enum Step: Int, CaseIterable {
        case welcome
        case startChoice
        case personalization
        case ready
    }

    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var studyGoal = ""
    @State private var selectedImportOption: ImportOption = .fresh
    @State private var animateBackdrop = false
    @State private var isAnkiImportPresented = false
    @State private var isQuizletImportPresented = false

    private enum ImportOption: String, CaseIterable, Identifiable {
        case fresh
        case anki
        case quizlet

        var id: String { rawValue }

        var title: String {
            switch self {
            case .fresh: return "Start fresh"
            case .anki: return "Import from Anki"
            case .quizlet: return "Import from Quizlet"
            }
        }

        var description: String {
            switch self {
            case .fresh:
                return "Create decks manually or import standard files when you're ready."
            case .anki:
                return "Bring over your existing review material and keep studying locally."
            case .quizlet:
                return "Paste an exported Quizlet set to turn it into a Revu deck instantly."
            }
        }

        var icon: String {
            switch self {
            case .fresh: return "sparkles"
            case .anki: return "square.and.arrow.down"
            case .quizlet: return "doc.on.clipboard"
            }
        }
    }

    private var progress: Double {
        Double(step.rawValue) / Double(Step.allCases.count - 1)
    }

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: DesignSystem.Spacing.xl) {
                header
                contentCard
                footer
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.vertical, DesignSystem.Spacing.lg)
            .frame(maxWidth: 1080)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animateBackdrop.toggle()
            }
        }
        .sheet(isPresented: $isAnkiImportPresented) {
            AnkiImportFlowView { _ in
                isAnkiImportPresented = false
                onComplete()
            }
        }
        .sheet(isPresented: $isQuizletImportPresented) {
            QuizletImportFlowView { _ in
                isQuizletImportPresented = false
                onComplete()
            }
        }
    }

    private var backdrop: some View {
        ZStack {
            DesignSystem.Colors.canvasBackground
                .ignoresSafeArea()

            Circle()
                .fill(DesignSystem.Colors.studyAccentMid.opacity(0.08))
                .frame(width: 520, height: 520)
                .blur(radius: 120)
                .offset(x: animateBackdrop ? -180 : -220, y: -180)

            Circle()
                .fill(DesignSystem.Colors.lightOverlay.opacity(0.5))
                .frame(width: 460, height: 460)
                .blur(radius: 96)
                .offset(x: animateBackdrop ? 220 : 180, y: 220)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image("BrandMarkDark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("Revu")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
            }

            Spacer()

            if step != .ready {
                Button("Skip setup", action: onSkip)
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.small)
                    .foregroundStyle(DesignSystem.Colors.tertiaryText)
            }
        }
    }

    private var contentCard: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(DesignSystem.Colors.subtleOverlay)
                    Rectangle()
                        .fill(DesignSystem.Colors.primaryText)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 2)

            HStack(alignment: .top, spacing: DesignSystem.Spacing.xxl) {
                narrative
                    .frame(width: 300, alignment: .leading)

                Divider()
                    .overlay(DesignSystem.Colors.separator)

                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignSystem.Spacing.xxl)
        }
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(DesignSystem.Colors.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 20, x: 0, y: 10)
        .frame(minHeight: 500)
    }

    private var narrative: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Text(stepTitle)
                .font(DesignSystem.Typography.hero)
                .foregroundStyle(DesignSystem.Colors.primaryText)

            Text(stepSubtitle)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.secondaryText)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                benefitRow(icon: "internaldrive", text: "Local-first storage with import and export support.")
                benefitRow(icon: "brain.head.profile", text: "FSRS-powered review scheduling tuned for long-term retention.")
                benefitRow(icon: "book.closed", text: "Decks, courses, exams, and study guides stay available offline.")
            }
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
            switch step {
            case .welcome:
                Text("Revu is a macOS study app built around active recall, local storage, and a focused review workflow.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            case .startChoice:
                VStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(ImportOption.allCases) { option in
                        startOptionCard(option)
                    }
                }
            case .personalization:
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    labeledField(title: "Your name", placeholder: "Optional", text: $name)
                    labeledField(title: "Main study goal", placeholder: "What are you studying for?", text: $studyGoal)
                    Text("These details stay on this Mac and only personalize local defaults and copy.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.tertiaryText)
                }
            case .ready:
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    Text("You're ready to build decks, import existing material, and start reviewing.")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Welcome, \(name).")
                            .font(DesignSystem.Typography.heading)
                            .foregroundStyle(DesignSystem.Colors.primaryText)
                    }
                }
            }
        }
    }

    private func startOptionCard(_ option: ImportOption) -> some View {
        Button {
            selectedImportOption = option
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                Image(systemName: option.icon)
                    .font(DesignSystem.Typography.subheading)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text(option.title)
                        .font(DesignSystem.Typography.bodyMedium)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                    Text(option.description)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }

                Spacer()

                Image(systemName: selectedImportOption == option ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedImportOption == option ? DesignSystem.Colors.studyAccentBright : DesignSystem.Colors.tertiaryText)
            }
            .padding(DesignSystem.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .stroke(selectedImportOption == option ? DesignSystem.Colors.studyAccentBorder : DesignSystem.Colors.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            if step != .welcome {
                Button("Back", action: goBack)
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
            }

            Spacer()

            Button(action: advance) {
                Text(step == .ready ? "Open Workspace" : "Continue")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Gradients.studyAccentDiagonal)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var stepTitle: String {
        switch step {
        case .welcome: return "Welcome to Revu"
        case .startChoice: return "Choose your starting point"
        case .personalization: return "Set a few local defaults"
        case .ready: return "Your workspace is ready"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .welcome:
            return "A local-first spaced repetition workspace for focused study."
        case .startChoice:
            return "Start with a clean library or bring over what you already use."
        case .personalization:
            return "Personalization here is lightweight and stays on-device."
        case .ready:
            return "You can always adjust settings, import more content, or reorganize later."
        }
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(DesignSystem.Typography.captionMedium)
                .foregroundStyle(DesignSystem.Colors.studyAccentBright)
                .frame(width: 18)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
        }
    }

    private func labeledField(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(DesignSystem.Typography.bodyMedium)
                .foregroundStyle(DesignSystem.Colors.primaryText)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.subtleOverlay)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.separator, lineWidth: 1)
                )
        }
    }

    private func goBack() {
        guard step.rawValue > 0, let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(DesignSystem.Animation.smooth) {
            step = previous
        }
    }

    private func advance() {
        if step == .ready {
            switch selectedImportOption {
            case .anki:
                isAnkiImportPresented = true
            case .quizlet:
                isQuizletImportPresented = true
            case .fresh:
                onComplete()
            }
            return
        }

        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        withAnimation(DesignSystem.Animation.smooth) {
            step = next
        }
    }
}
