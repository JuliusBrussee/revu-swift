import SwiftUI

struct SettingsView: View {
    @Environment(\.storage) private var storage
    @EnvironmentObject private var commandCenter: WorkspaceCommandCenter
    @State private var settings: UserSettings = UserSettings()
    @State private var notificationTime: Date = Date()
    @State private var isLoaded = false
    @State private var retentionPreset: RetentionPreset = .custom
    @State private var isAnkiImportPresented = false
    @State private var isQuizletImportPresented = false
    @StateObject private var dataManagement = SettingsDataManagementViewModel(storage: DataController.shared.storage)
    @State private var destructiveAction: DestructiveAction?
    @State private var alert: SettingsAlert?

    var body: some View {
        Group {
            if isLoaded {
                WorkspaceCanvas { _ in
                    CanvasBlock {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                            Text("Settings")
                                .font(DesignSystem.Typography.hero)
                                .foregroundStyle(.primary)
                            
                            Text("Customize your learning experience")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    CanvasBlock(title: "Appearance", subtitle: "Personalize the look and feel") {
                        appearanceSection
                    }
                    
                    CanvasBlock(title: "Local App", subtitle: "This open-source build runs fully on-device") {
                        accountSection
                    }
                    
                    CanvasBlock(title: "Daily Limits", subtitle: "Control your study pace") {
                        settingsSection
                    }
                    
                    CanvasBlock(title: "Scheduler", subtitle: "Fine-tune the adaptive scheduler") {
                        schedulingSection
                    }

                    CanvasBlock(title: "Adaptive Engine", subtitle: "Proactive hints and coaching") {
                        adaptiveEngineSection
                    }
                    
                    CanvasBlock(title: "Notifications", subtitle: "Stay on track with reminders") {
                        notificationsSection
                    }
                    
                    CanvasBlock(title: "Data & Sync", subtitle: "Manage your study data") {
                        miscSection
                    }

                    CanvasBlock(title: "Delete All", subtitle: "Danger zone actions") {
                        deleteAllSection
                    }
                }
            } else {
                VStack(spacing: DesignSystem.Spacing.lg) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading settings…")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await loadSettings() }
        .sheet(isPresented: $isAnkiImportPresented) {
            AnkiImportFlowView()
        }
        .sheet(isPresented: $isQuizletImportPresented) {
            QuizletImportFlowView()
        }
        .confirmationDialog(
            destructiveAction?.dialogTitle ?? "",
            isPresented: Binding(
                get: { destructiveAction != nil },
                set: { if !$0 { destructiveAction = nil } }
            )
        ) {
            if let action = destructiveAction {
                Button(action.confirmTitle, role: action.confirmRole) {
                    destructiveAction = nil
                    Task { await performDestructiveAction(action) }
                }
            }
            Button("Cancel", role: .cancel) {
                destructiveAction = nil
            }
        } message: {
            Text(destructiveAction?.dialogMessage ?? "")
        }
        .alert(
            alert?.title ?? "",
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            )
        ) {
            Button("OK", role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            DesignSystemSegmentedPicker(
                selection: binding(\UserSettings.appearanceMode),
                items: AppearanceMode.allCases.map { DesignSystemSegment(label: $0.rawValue, value: $0) }
            )
            
            Callout(
                "Choose how Revu looks. System follows your macOS appearance settings.",
                style: .info
            )
        }
    }
    
    // MARK: - Account Section
    
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.subtleOverlay)
                        .frame(width: 48, height: 48)

                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 20))
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Local-first build")
                        .font(DesignSystem.Typography.bodyMedium)
                        .foregroundStyle(DesignSystem.Colors.primaryText)

                    Text("Decks, cards, exams, and study guides stay on this Mac.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.secondaryText)
                }

                Spacer()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            Callout(
                "This open-source build does not include accounts, subscriptions, cloud billing, or hosted AI services.",
                style: .info,
                title: "Public repo scope"
            )
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("New cards per day")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Maximum number of new cards to introduce each day")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(settings.dailyNewLimit)")
                        .dynamicSystemFont(size: 24, weight: .semibold, design: .rounded, relativeTo: .title2)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 60)
                }
                
                Stepper("", value: binding(\UserSettings.dailyNewLimit), in: 0...100)
                    .labelsHidden()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Reviews per day")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Maximum number of cards to review each day")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(settings.dailyReviewLimit)")
                        .dynamicSystemFont(size: 24, weight: .semibold, design: .rounded, relativeTo: .title2)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 60)
                }
                
                Stepper("", value: binding(\UserSettings.dailyReviewLimit), in: 0...1000, step: 10)
                    .labelsHidden()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )
        }
    }

    private var schedulingSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                DesignSystemSegmentedPicker(
                    selection: $retentionPreset,
                    items: RetentionPreset.allCases.map { DesignSystemSegment(label: $0.title, value: $0) }
                )
                .onChange(of: retentionPreset) { oldPreset, newPreset in
                    guard isLoaded else { return }
                    guard newPreset != .custom else { return }
                    if let value = newPreset.retentionValue {
                        settings.retentionTarget = value
                        Task { await saveSettings() }
                    }
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Retention target")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("FSRS spaces reviews to keep recall near this goal.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(settings.retentionPercentage)%")
                        .dynamicSystemFont(size: 24, weight: .semibold, design: .rounded, relativeTo: .title2)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 68)
                }

                DesignSystemSlider(
                    value: Binding(
                        get: { settings.retentionTarget },
                        set: { newValue in
                            let clamped = min(max(newValue, 0.7), 0.97)
                            settings.retentionTarget = clamped
                            retentionPreset = RetentionPreset.matching(value: clamped)
                            Task { await saveSettings() }
                        }
                    ),
                    range: 0.7...0.97,
                    step: 0.01
                )
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Spacing preview")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.primary)
                Text("FSRS projects these first-review intervals at your selected retention goal.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(fsrsPreviewRows, id: \.label) { row in
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                            Text(row.label)
                                .font(DesignSystem.Typography.captionMedium)
                                .foregroundStyle(.secondary)
                            Text(row.detail)
                                .font(DesignSystem.Typography.bodyMedium)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Adjust for response speed")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Faster answers push reviews further out; slower answers pull them closer.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesignSystemToggle(isOn: binding(\UserSettings.enableResponseTimeTuning))
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            Callout(
                "Retention between 70–97% lets you balance total reviews with confidence on exam day. Use the presets for quick tuning or slide to any custom value.",
                style: .info,
                title: "Adaptive spacing"
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Learning steps (minutes)")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.primary)
                DesignSystemTextField(
                    placeholder: "e.g., 1,10,1440",
                    text: Binding(
                        get: { settings.learningStepsMinutes.map { String(Int($0)) }.joined(separator: ",") },
                        set: { input in
                            let values = input.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                            settings.learningStepsMinutes = values
                            Task { await saveSettings() }
                        }
                    )
                )
            }
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Lapse steps (minutes)")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.primary)
                DesignSystemTextField(
                    placeholder: "e.g., 10",
                    text: Binding(
                        get: { settings.lapseStepsMinutes.map { String(Int($0)) }.joined(separator: ",") },
                        set: { input in
                            let values = input.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                            settings.lapseStepsMinutes = values
                            Task { await saveSettings() }
                        }
                    )
                )
            }
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Minimum ease factor")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Cards won't fall below this multiplier")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.2f", settings.easeMin))
                        .font(DesignSystem.Typography.heading)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 60)
                }
                
                Stepper("", value: binding(\UserSettings.easeMin), in: 1.3...3.0, step: 0.05)
                    .labelsHidden()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )
            
            LabeledDivider(label: "Study Options")
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Bury sibling cards")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Hide related cards until next session")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesignSystemToggle(isOn: binding(\UserSettings.burySiblings))
                }

                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Show keyboard hints")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Display shortcuts during study sessions")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesignSystemToggle(isOn: binding(\UserSettings.keyboardHints))
                }

                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Auto-advance cards")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Automatically move to next card after grading")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesignSystemToggle(isOn: binding(\UserSettings.autoAdvance))
                }
            }
        }
    }

    private var adaptiveEngineSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Proactive help")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Show gentle hints or coaching when you seem stuck.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesignSystemToggle(isOn: binding(\UserSettings.proactiveInterventionsEnabled))
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Sensitivity")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.primary)
                DesignSystemSegmentedPicker(
                    selection: binding(\UserSettings.interventionSensitivity),
                    items: InterventionSensitivity.allCases.map { DesignSystemSegment(label: $0.displayName, value: $0) }
                )

                Text("Less interruption ↔ more help")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.tertiaryText)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Cooldown")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Minimum minutes between proactive prompts.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(settings.interventionCooldownMinutes)m")
                        .dynamicSystemFont(size: 22, weight: .semibold, design: .rounded, relativeTo: .title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 56)
                }

                Stepper("", value: binding(\UserSettings.interventionCooldownMinutes), in: 0...60, step: 5)
                    .labelsHidden()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Default challenge mode")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Prioritize harder and lapsed cards in new sessions.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    DesignSystemToggle(isOn: binding(\UserSettings.challengeModeDefaultEnabled))
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Celebration intensity")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.primary)
                DesignSystemSegmentedPicker(
                    selection: binding(\UserSettings.celebrationIntensity),
                    items: CelebrationIntensity.allCases.map { DesignSystemSegment(label: $0.displayName, value: $0) }
                )
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                        Text("Daily goal target")
                            .font(DesignSystem.Typography.bodyMedium)
                            .foregroundStyle(.primary)
                        Text("Cards to aim for each day.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(settings.dailyGoalTarget)")
                        .dynamicSystemFont(size: 22, weight: .semibold, design: .rounded, relativeTo: .title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 56)
                }

                Stepper("", value: binding(\UserSettings.dailyGoalTarget), in: 5...300, step: 5)
                    .labelsHidden()
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
            )
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text("Enable daily reminder")
                        .font(DesignSystem.Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    Text("Get notified when it's time to review")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DesignSystemToggle(isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { newValue in
                        settings.notificationsEnabled = newValue
                        Task {
                            await saveSettings()
                            if newValue {
                                NotificationService.shared.requestAuthorization()
                                NotificationService.shared.scheduleDailyReminder(for: settings)
                            } else {
                                NotificationService.shared.cancelReminders()
                            }
                        }
                    }
                ))
            }
            
            if settings.notificationsEnabled {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("Reminder time")
                        .font(DesignSystem.Typography.bodyMedium)
                        .foregroundStyle(.primary)
                    
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { notificationTime },
                            set: { value in
                                notificationTime = value
                                let comps = Calendar.current.dateComponents([.hour, .minute], from: value)
                                settings.notificationHour = comps.hour ?? settings.notificationHour
                                settings.notificationMinute = comps.minute ?? settings.notificationMinute
                                Task {
                                    await saveSettings()
                                    NotificationService.shared.scheduleDailyReminder(for: settings)
                                }
                            }
                        ),
                        displayedComponents: [.hourAndMinute]
                    )
                    .labelsHidden()
                    .datePickerStyle(.graphical)
                }
                .padding(DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.subtleOverlay)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(DesignSystem.Animation.smooth, value: settings.notificationsEnabled)
    }

    private var miscSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Callout(
                "Data is stored locally in the app sandbox. Export decks regularly if you want portable backups.",
                style: .info,
                title: "About Data Storage"
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Import")
                    .font(DesignSystem.Typography.heading)
                    .foregroundStyle(.primary)
                Text("Bring your existing study material into Revu from other apps.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)

                Button {
                    isAnkiImportPresented = true
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(DesignSystem.Typography.bodyMedium)
                        Text("Import from Anki…")
                            .font(DesignSystem.Typography.bodyMedium)
                    }
                    .primaryButtonStyle()
                }
                .buttonStyle(.plain)

                Button {
                    isQuizletImportPresented = true
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "doc.on.clipboard")
                            .font(DesignSystem.Typography.bodyMedium)
                        Text("Import from Quizlet…")
                            .font(DesignSystem.Typography.bodyMedium)
                    }
                    .primaryButtonStyle()
                }
                .buttonStyle(.plain)

                Text("No data leaves your device.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Onboarding")
                    .font(DesignSystem.Typography.heading)
                    .foregroundStyle(.primary)
                Text("Replay the Arc/Notion-inspired tour whenever you want.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)

                Button {
                    settings.hasCompletedOnboarding = false
                    Task {
                        await saveSettings()
                        commandCenter.presentOnboarding()
                    }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "play.rectangle.on.rectangle")
                            .font(DesignSystem.Typography.bodyMedium)
                        Text("Replay onboarding flow")
                            .font(DesignSystem.Typography.bodyMedium)
                    }
                    .primaryButtonStyle()
                }
                .buttonStyle(.plain)

                Text("No data leaves your device. You can dismiss anytime.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var deleteAllSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            Callout(
                "These actions modify or remove your local library. Deleting is permanent, so export your decks first if you need a backup.",
                style: .warning,
                title: "Be careful"
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                destructiveActionRow(
                    title: "Delete all local data",
                    detail: "Removes decks, cards, review history, settings, and attachments from this device.",
                    systemImage: "trash.fill",
                    style: .destructive
                ) {
                    destructiveAction = .wipeAllLocalData
                }

                destructiveActionRow(
                    title: "Remove all decks",
                    detail: "Deletes all decks and cards (your settings stay).",
                    systemImage: "folder.badge.minus",
                    style: .destructive
                ) {
                    destructiveAction = .removeAllDecks
                }

                destructiveActionRow(
                    title: "Archive all decks",
                    detail: "Moves every deck to Archive and suspends its cards. You can restore later.",
                    systemImage: "archivebox.fill",
                    style: .secondary
                ) {
                    destructiveAction = .archiveAllDecks
                }
            }

            if dataManagement.isWorking {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView()
                    Text("Applying changes…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(dataManagement.isWorking)
    }

    private enum ActionRowStyle {
        case destructive
        case secondary
    }

    private func destructiveActionRow(
        title: String,
        detail: String,
        systemImage: String,
        style: ActionRowStyle,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(title)
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: style == .destructive ? .destructive : nil) {
                action()
            } label: {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: systemImage)
                        .font(DesignSystem.Typography.bodyMedium)
                    Text(title)
                        .font(DesignSystem.Typography.bodyMedium)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(style == .destructive ? Color.red : DesignSystem.Colors.hoverBackground)
                )
                .foregroundStyle(style == .destructive ? Color.white : Color.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.subtleOverlay)
        )
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<UserSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                Task { await saveSettings() }
            }
        )
    }

    private enum RetentionPreset: String, CaseIterable, Identifiable {
        case gentle
        case balanced
        case focused
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .gentle:
                return "Gentle"
            case .balanced:
                return "Balanced"
            case .focused:
                return "Focused"
            case .custom:
                return "Custom"
            }
        }

        var retentionValue: Double? {
            switch self {
            case .gentle:
                return 0.75
            case .balanced:
                return 0.85
            case .focused:
                return 0.92
            case .custom:
                return nil
            }
        }

        static func matching(value: Double) -> RetentionPreset {
            if abs(value - 0.75) < 0.001 { return .gentle }
            if abs(value - 0.85) < 0.001 { return .balanced }
            if abs(value - 0.92) < 0.001 { return .focused }
            return .custom
        }
    }

    private var fsrsPreviewRows: [(label: String, detail: String)] {
        let parameters = FSRSParameters(requestedRetention: settings.retentionTarget)
        let sampleGrades: [ReviewGrade] = [.hard, .good, .easy]
        return sampleGrades.map { grade in
            let stability = parameters.initialStability(for: grade)
            let intervalSeconds = parameters.intervalSeconds(for: stability)
            let days = intervalSeconds / 86_400.0
            return (
                label: grade == .hard ? "Hard" : (grade == .good ? "Good" : "Easy"),
                detail: "≈\(formattedDays(days)) between reviews"
            )
        }
    }

    private func formattedDays(_ days: Double) -> String {
        if days < 1 {
            let hours = max(1, Int((days * 24).rounded()))
            return "\(hours)h"
        }
        if days < 10 {
            return String(format: "%.1fd", days)
        }
        return String(format: "%.0fd", days.rounded())
    }

    private func loadSettings() async {
        let loaded = (try? await storage.loadSettings())?.toDomain() ?? UserSettings()
        let comps = DateComponents(hour: loaded.notificationHour, minute: loaded.notificationMinute)
        await MainActor.run {
            settings = loaded
            notificationTime = Calendar.current.date(from: comps) ?? Date()
            isLoaded = true
            retentionPreset = RetentionPreset.matching(value: loaded.retentionTarget)
        }
    }

    private func saveSettings() async {
        do {
            try await storage.save(settings: settings.toDTO())
        } catch {
            print("Failed to save settings: \(error)")
        }
    }

    private func performDestructiveAction(_ action: DestructiveAction) async {
        do {
            switch action {
            case .wipeAllLocalData:
                try await dataManagement.deleteAllLocalData()
                await loadSettings()
                await MainActor.run {
                    alert = SettingsAlert(
                        title: "Local data deleted",
                        message: "Revu reset this device to a fresh state."
                    )
                }
            case .removeAllDecks:
                try await dataManagement.removeAllDecks()
                await MainActor.run {
                    alert = SettingsAlert(
                        title: "Decks deleted",
                        message: "All decks and cards were removed from this device."
                    )
                }
            case .archiveAllDecks:
                try await dataManagement.archiveAllDecks()
                await MainActor.run {
                    alert = SettingsAlert(
                        title: "Decks archived",
                        message: "All decks were moved to Archive and their cards were suspended."
                    )
                }
            }
        } catch {
            await MainActor.run {
                alert = SettingsAlert(
                    title: "Action failed",
                    message: error.localizedDescription
                )
            }
        }
    }
}

private enum DestructiveAction: Identifiable {
    case wipeAllLocalData
    case removeAllDecks
    case archiveAllDecks

    var id: String {
        switch self {
        case .wipeAllLocalData: return "wipeAllLocalData"
        case .removeAllDecks: return "removeAllDecks"
        case .archiveAllDecks: return "archiveAllDecks"
        }
    }

    var confirmTitle: String {
        switch self {
        case .wipeAllLocalData: return "Delete all local data"
        case .removeAllDecks: return "Delete all decks"
        case .archiveAllDecks: return "Archive all decks"
        }
    }

    var confirmRole: ButtonRole? {
        switch self {
        case .archiveAllDecks:
            return nil
        case .wipeAllLocalData, .removeAllDecks:
            return .destructive
        }
    }

    var dialogTitle: String {
        switch self {
        case .wipeAllLocalData:
            return "Delete all local data?"
        case .removeAllDecks:
            return "Delete all decks?"
        case .archiveAllDecks:
            return "Archive all decks?"
        }
    }

    var dialogMessage: String {
        switch self {
        case .wipeAllLocalData:
            return "This permanently removes all decks, cards, review history, settings, and attachments from this device."
        case .removeAllDecks:
            return "This permanently deletes all decks and cards on this device. Your preferences stay."
        case .archiveAllDecks:
            return "This moves every deck to Archive and suspends its cards. You can restore decks later."
        }
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#if DEBUG
#Preview("SettingsView") {
    RevuPreviewHost { _ in
        SettingsView()
            .frame(width: 1100, height: 820)
    }
}
#endif
