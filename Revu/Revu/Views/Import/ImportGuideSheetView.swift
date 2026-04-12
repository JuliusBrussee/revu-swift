import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ImportGuideSheetView: View {
    let onDismiss: () -> Void
    let onChooseFile: () -> Void
    var onQuizletImport: (() -> Void)? = nil
    
    @State private var isAppearing = false
    @State private var selectedTab: ImportTab = .prompts

    private enum ImportTab: String, CaseIterable {
        case prompts = "AI Prompts"
        case templates = "Templates"
        case tips = "Tips"

        var icon: String {
            switch self {
            case .prompts: return "sparkles"
            case .templates: return "doc.on.doc"
            case .tips: return "lightbulb"
            }
        }
    }

    var body: some View {
        ZStack {
            backgroundView

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heroSection
                            .padding(.horizontal, DesignSystem.Spacing.xl)
                            .padding(.top, DesignSystem.Spacing.lg)
                            .padding(.bottom, DesignSystem.Spacing.lg)

                        tabSelector
                            .padding(.horizontal, DesignSystem.Spacing.xl)
                            .padding(.bottom, DesignSystem.Spacing.lg)
                            .offset(y: isAppearing ? 0 : 12)
                            .opacity(isAppearing ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.06), value: isAppearing)

                        tabContent
                            .padding(.horizontal, DesignSystem.Spacing.xl)
                            .padding(.bottom, DesignSystem.Spacing.xxl)
                            .offset(y: isAppearing ? 0 : 12)
                            .opacity(isAppearing ? 1 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.12), value: isAppearing)
                    }
                }

                footerActions
            }
        }
        .frame(minWidth: 780, minHeight: 620)
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                isAppearing = true
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        DesignSystem.Colors.sidebarBackground
            .ignoresSafeArea()
    }
    
    // MARK: - Hero Section
    
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Icon badge
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.subtleOverlay)
                    .frame(width: 56, height: 56)
                
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.primaryText)
            }
            .offset(y: isAppearing ? 0 : -10)
            .opacity(isAppearing ? 1 : 0)
            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isAppearing)
            
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("Import Decks")
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Text("Bring your decks from spreadsheets, Markdown, or Revu exports. Use AI prompts to generate perfectly formatted content.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .offset(y: isAppearing ? 0 : 10)
            .opacity(isAppearing ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.05), value: isAppearing)
            
            // Format badges
            HStack(spacing: DesignSystem.Spacing.sm) {
                FormatBadge(icon: "arrow.triangle.2.circlepath", label: "Anki")
                FormatBadge(icon: "doc.text", label: "Markdown")
                FormatBadge(icon: "tablecells", label: "CSV")
                FormatBadge(icon: "curlybraces", label: "JSON")
                FormatBadge(icon: "doc.on.clipboard", label: "Quizlet")
            }
            .offset(y: isAppearing ? 0 : 10)
            .opacity(isAppearing ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.85).delay(0.08), value: isAppearing)
        }
    }
    
    // MARK: - Tab Selector
    
    private var tabSelector: some View {
        HStack(spacing: 4) {
            ForEach(ImportTab.allCases, id: \.self) { tab in
                ImportTabButton(
                    title: tab.rawValue,
                    icon: tab.icon,
                    isSelected: selectedTab == tab
                ) {
                    withAnimation(DesignSystem.Animation.quick) {
                        selectedTab = tab
                    }
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .stroke(DesignSystem.Colors.separator, lineWidth: 1)
        )
    }
    
    // MARK: - Tab Content
    
    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .prompts:
            promptsContent
        case .templates:
            templatesContent
        case .tips:
            tipsContent
        }
    }
    
    private var promptsContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ImportGuideSectionHeader(
                title: "Ready-made AI Prompts",
                subtitle: "Copy these master prompts to generate Revu-ready decks with Claude, GPT, or any AI assistant."
            )
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 400), spacing: 16)], spacing: 16) {
                ForEach(ImportReferenceCardEntry.promptLibrary) { entry in
                    PremiumReferenceCard(entry: entry)
                }
            }
        }
    }
    
    private var templatesContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ImportGuideSectionHeader(
                title: "Import-Ready Templates",
                subtitle: "Copy a template per question type, customize the content, then drop it into your file."
            )
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 400), spacing: 16)], spacing: 16) {
                ForEach(ImportReferenceCardEntry.templateLibrary) { entry in
                    PremiumReferenceCard(entry: entry)
                }
            }
        }
    }
    
    private var tipsContent: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ImportGuideSectionHeader(
                title: "Quick Tips",
                subtitle: "Make the most of your imports with these helpful suggestions."
            )
            
            VStack(spacing: DesignSystem.Spacing.md) {
                TipCard(
                    icon: "doc.on.clipboard",
                    title: "Start from an export",
                    description: "Export an existing deck to JSON to get a template that already includes every field.",
                    color: DesignSystem.Colors.primaryText
                )
                
                TipCard(
                    icon: "sparkles",
                    title: "LLM-friendly format",
                    description: "Share the format example with your AI assistant so it returns structured content that imports cleanly.",
                    color: DesignSystem.Colors.primaryText
                )
                
                TipCard(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Re-import to update",
                    description: "Using the same deck and card IDs lets you re-import to merge changes instead of creating duplicates.",
                    color: DesignSystem.Colors.primaryText
                )
                
                TipCard(
                    icon: "checkmark.shield",
                    title: "Preview before import",
                    description: "Revu validates your file and shows a preview so you can catch issues before importing.",
                    color: DesignSystem.Colors.primaryText
                )
            }
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack {
            Button(action: onDismiss) {
                Text("Close")
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.hoverBackground)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()

            if let onQuizletImport {
                Button(action: onQuizletImport) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 13, weight: .medium))
                        Text("Import from Quizlet…")
                            .font(DesignSystem.Typography.bodyMedium)
                    }
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.hoverBackground)
                    )
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.separator, lineWidth: 1)
                    )
                }
                .buttonStyle(ImportButtonStyle())
            }

            Button(action: onChooseFile) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 13, weight: .medium))
                    Text("Choose File…")
                        .font(DesignSystem.Typography.bodyMedium)
                }
                .foregroundStyle(DesignSystem.Colors.canvasBackground)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(
                    Capsule()
                        .fill(DesignSystem.Colors.primaryText)
                )
            }
            .buttonStyle(ImportButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignSystem.Spacing.xl)
        .padding(.vertical, DesignSystem.Spacing.lg)
        .background(
            Rectangle()
                .fill(DesignSystem.Colors.window)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignSystem.Colors.separator)
                .frame(height: 1)
        }
    }
}

// MARK: - Supporting Components

private struct FormatBadge: View {
    let icon: String
    let label: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(label)
                .font(DesignSystem.Typography.captionMedium)
        }
        .foregroundStyle(DesignSystem.Colors.secondaryText)
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(DesignSystem.Colors.hoverBackground)
        )
    }
}

private struct ImportTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var foreground: Color {
        isSelected ? DesignSystem.Colors.primaryText : DesignSystem.Colors.tertiaryText
    }

    private var background: Color {
        if isSelected {
            return DesignSystem.Colors.subtleOverlay
        }
        if isHovered {
            return DesignSystem.Colors.hoverBackground
        }
        return .clear
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(title)
                    .font(DesignSystem.Typography.bodyMedium)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(DesignSystem.Animation.quick, value: isSelected)
        .animation(DesignSystem.Animation.quick, value: isHovered)
    }
}

private struct ImportGuideSectionHeader: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(DesignSystem.Typography.heading)
                .foregroundStyle(DesignSystem.Colors.primaryText)
            
            Text(subtitle)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PremiumReferenceCard: View {
    let entry: ImportReferenceCardEntry
    
    @State private var copied = false
    @State private var isHovered = false
    @State private var isExpanded = false


    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            // Header
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.subtleOverlay)
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: entry.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(DesignSystem.Typography.bodyMedium)
                        .foregroundStyle(DesignSystem.Colors.primaryText)
                    
                    Text(entry.subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.tertiaryText)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // Copy button
                Button(action: copy) {
                    ZStack {
                        Circle()
                            .fill(copied ? DesignSystem.Colors.subtleOverlay : DesignSystem.Colors.hoverBackground)
                            .frame(width: 32, height: 32)

                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(copied ? DesignSystem.Colors.primaryText : DesignSystem.Colors.secondaryText)
                    }
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied!" : "Copy to clipboard")
            }
            
            // Content preview
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.content)
                    .font(entry.contentKind == .code ? .system(.caption, design: .monospaced) : DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.primaryText.opacity(0.85))
                    .lineLimit(isExpanded ? nil : 6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                if entry.content.split(separator: "\n").count > 6 {
                    Button {
                        withAnimation(DesignSystem.Animation.smooth) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show less" : "Show more")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, DesignSystem.Spacing.sm)
                }
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.lightOverlay)
            )
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .fill(isHovered ? DesignSystem.Colors.hoverBackground : DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .stroke(isHovered ? DesignSystem.Colors.borderOverlay : DesignSystem.Colors.separator, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .animation(DesignSystem.Animation.quick, value: isHovered)
    }
    
    private func copy() {
        copyTextToPasteboard(entry.content)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.2)) {
                copied = false
            }
        }
    }
}

private struct TipCard: View {
    let icon: String
    let title: String
    let description: String
    let color: Color
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            // Icon
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 44, height: 44)
                
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(color)
            }
            
            // Content
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(title)
                    .font(DesignSystem.Typography.bodyMedium)
                    .foregroundStyle(DesignSystem.Colors.primaryText)
                
                Text(description)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .fill(isHovered ? DesignSystem.Colors.hoverBackground : DesignSystem.Colors.window)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.xl, style: .continuous)
                .stroke(
                    isHovered ? color.opacity(0.2) : DesignSystem.Colors.separator,
                    lineWidth: 1
                )
        )
        .onHover { isHovered = $0 }
        .animation(DesignSystem.Animation.quick, value: isHovered)
    }
}

private struct ImportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Data Models

private struct ImportReferenceCardEntry: Identifiable {
    enum Category {
        case prompt
        case template
    }

    enum ContentKind {
        case prose
        case code
    }

    let id: String
    let category: Category
    let title: String
    let subtitle: String
    let icon: String
    let content: String
    let contentKind: ContentKind
}

private extension ImportReferenceCardEntry {
    static let promptLibrary: [ImportReferenceCardEntry] = [
        ImportReferenceCardEntry(
            id: "markdown-master",
            category: .prompt,
            title: "Master prompt · Markdown blocks",
            subtitle: "High-quality blocks separated by `---` for basic, cloze, and multiple choice. Supports LaTeX/KaTeX ($...$, $$...$$).",
            icon: "sparkles",
            content: """
Role: You are an expert spaced‑repetition author. Produce Revu‑importable Markdown blocks only.

Quality rules:
- Atomic: one fact per card, unambiguous, testable.
- Concise: keep `back` ≤ 25 words for basic; no fluff.
- No duplicates; vary cognition (recall, recognition, light application).
- Ground strictly in the provided material; do not invent facts.

Output format per card (YAML‑ish block), then a line with `---` between cards:
deck: <Deck Name>
kind: basic | cloze | multipleChoice
# basic
front: <clear question>
back: <concise answer, optional brief rationale. Math allowed: $e^{i\\pi}+1=0$.>
# cloze
cloze: <context with {{c1::hidden term}}>
back: <hidden term. Math allowed in context with $...$ or $$...$$.>
# multipleChoice
prompt: <question>
choices:
  - <option A>
  - <option B>
  - <option C>
  - <option D>
correct: <exact text of the correct option>
back: <1–2 sentence explanation>
tags:
  - <optional tag>

Constraints:
- Exactly 4 choices for multiple choice; one correct.
- Make choices similar in length/style; avoid giveaways.
- Use `---` as the only separator; no code fences or extra commentary.
- Generate at least 15 cards grouped into sensible `deck:` names.
- Math: Inline `$...$` or `\\(...\\)`, block `$$...$$` or `\\[...\\]` render with SwiftMath (KaTeX/LaTeX syntax). Keep LaTeX commands to math mode basics (fractions, superscripts, sums, integrals).
""",
            contentKind: .prose
        ),
        ImportReferenceCardEntry(
            id: "spreadsheet-master",
            category: .prompt,
            title: "Master prompt · Spreadsheet/CSV",
            subtitle: "Emit clean CSV with a header covering all card kinds.",
            icon: "tablecells",
            content: """
Role: Output only valid CSV that Revu can import. No prose.

Header (first row exactly):
deck,kind,front,back,cloze,choices,correct,tags

Rules:
- `kind` ∈ {basic,cloze,multipleChoice}.
- basic: put the question in `front`, concise answer in `back`; leave `cloze`,`choices`,`correct` empty.
- cloze: put full context with {{c1::hidden term}} in `cloze`; put hidden term in `back`; leave `front`,`choices`,`correct` empty.
- multipleChoice: put the question in `front`; put exactly four options in `choices` joined by `|` (e.g. "Paris|Lyon|Nice|Marseille"); set `correct` to the exact correct option text; give a brief rationale in `back`.
- Put comma‑containing fields in quotes; keep choices pipe‑separated even inside quotes.
- `tags` is a `|`‑separated list (or empty).
- Produce at least 20 rows grouped into sensible `deck` names.

Return only the CSV (include the header). No markdown fences.
""",
            contentKind: .prose
        ),
        ImportReferenceCardEntry(
            id: "json-blueprint-master",
            category: .prompt,
            title: "Master prompt · JSON deck blueprint",
            subtitle: "Emit one JSON object that matches Revu's deck schema.",
            icon: "curlybraces.square",
            content: """
Role: Output a single valid JSON object representing a Revu deck blueprint. No prose.

Quality rules:
- Cards are atomic, unambiguous, and concise; no duplicates.
- Mix recall/recognition with some understanding/application.
- Ground in the provided material only.

Format (field names exact):
{
  "name": "<Deck Name>",
  "summary": "<one‑paragraph summary>",
  "tags": ["tag1","tag2"],
  "cards": [
    { "kind": "basic", "front": "<question>", "back": "<concise answer>" },
    { "kind": "cloze", "front": "Fill in the missing term.", "back": "<hidden term>", "clozeSource": "... {{c1::<hidden term>::label}} ..." },
    { "kind": "multipleChoice", "front": "<question>", "back": "<brief rationale>", "choices": ["A","B","C","D"], "correctChoiceIndex": 2 }
  ]
}

Constraints:
- Exactly 4 options for multipleChoice; one correct; zero‑based `correctChoiceIndex`.
- Valid UTF‑8 JSON; no markdown fences, comments, or trailing commas.
- Produce 20–40 cards depending on material quality.
""",
            contentKind: .prose
        )
    ]

    static let templateLibrary: [ImportReferenceCardEntry] = [
        ImportReferenceCardEntry(
            id: "template-basic",
            category: .template,
            title: "Template · Basic flashcard",
            subtitle: "Drop into Markdown or convert to a CSV row for simple Q&A.",
            icon: "rectangle.and.pencil.and.ellipsis",
            content: """
deck: Cellular Energy
kind: basic
front: Which organelle is known as the powerhouse of the cell?
back: Mitochondria
tags:
  - bio101
  - exam-prep
---
""",
            contentKind: .code
        ),
        ImportReferenceCardEntry(
            id: "template-cloze",
            category: .template,
            title: "Template · Cloze deletion",
            subtitle: "Uses the `{{c1::answer}}` syntax Revu expects for cloze cards.",
            icon: "highlighter",
            content: """
deck: Biochemistry Drills
kind: cloze
cloze: The electron transport chain occurs in the {{c1::inner mitochondrial membrane}}.
tags:
  - biochem
  - metabolism
---
""",
            contentKind: .code
        ),
        ImportReferenceCardEntry(
            id: "template-mcq",
            category: .template,
            title: "Template · Multiple choice",
            subtitle: "Shows prompt, choice list, correct answer, and optional explanation.",
            icon: "list.bullet.rectangle",
            content: """
deck: Color Theory
kind: multipleChoice
prompt: Which pigments form the subtractive CMYK primary set?
choices:
  - Cyan
  - Magenta
  - Yellow
  - Black (Key)
correct: Cyan
back: CMYK pigments absorb light; cyan plus magenta plus yellow mix to dark values while black is the key plate.
tags:
  - design
  - fundamentals
---
""",
            contentKind: .code
        )
    ]
}

private func copyTextToPasteboard(_ text: String) {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#endif
}

#if DEBUG
#Preview("ImportGuideSheetView") {
    ImportGuideSheetView(
        onDismiss: {},
        onChooseFile: {}
    )
    .frame(width: 980, height: 720)
}
#endif
