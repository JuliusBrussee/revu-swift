import Foundation
import Combine

@MainActor
final class QuizletImportFlowViewModel: ObservableObject {
    enum Phase {
        case input
        case preview(ImportPreview)
        case importing
    }

    @Published var deckName: String = ""
    @Published var pastedText: String = ""
    @Published private(set) var phase: Phase = .input
    @Published private(set) var errorMessage: String?

    private let storage: Storage

    init(storage: Storage) {
        self.storage = storage
    }

    var canPreview: Bool {
        !deckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func loadPreview() {
        errorMessage = nil
        let name = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let importer = QuizletImporter(deckName: name, storage: storage)
        do {
            let details = try importer.loadPreview(from: text)
            let preview = ImportPreview(
                formatIdentifier: "quizlet",
                formatName: "Quizlet Export",
                deckCount: details.deckCount,
                cardCount: details.cardCount,
                decks: details.decks,
                errors: details.errors
            )
            phase = .preview(preview)
        } catch let error as ImportErrorDetail {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func performImport(mergePlan: DeckMergePlan, onComplete: @escaping (ImportResult) -> Void) {
        let name = deckName.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .importing
        errorMessage = nil

        Task {
            let importer = QuizletImporter(deckName: name, storage: storage)
            do {
                let result = try await importer.performImport(from: text, mergePlan: mergePlan)
                onComplete(result)
            } catch let error as ImportErrorDetail {
                self.errorMessage = error.message
                self.phase = .input
            } catch {
                self.errorMessage = error.localizedDescription
                self.phase = .input
            }
        }
    }

    func reset() {
        phase = .input
        errorMessage = nil
    }
}
