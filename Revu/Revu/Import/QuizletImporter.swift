import Foundation

final class QuizletImporter {
    private let deckName: String
    private let writer: DeckImportWriter

    init(deckName: String, storage: Storage) {
        self.deckName = deckName
        self.writer = DeckImportWriter(storage: storage)
    }

    func loadPreview(from text: String) throws -> ImportPreviewDetails {
        let (document, errors) = parseDocument(from: text)
        let deckSummaries = document.decks.map { deck in
            ImportPreview.DeckSummary(
                id: deck.id,
                name: deck.name,
                cardCount: deck.cards.count,
                token: deck.token
            )
        }
        return ImportPreviewDetails(
            deckCount: document.decks.count,
            cardCount: document.decks.reduce(0) { $0 + $1.cards.count },
            decks: deckSummaries,
            errors: errors
        )
    }

    func performImport(from text: String, mergePlan: DeckMergePlan) async throws -> ImportResult {
        let (document, errors) = parseDocument(from: text)
        let result = try await writer.importDocument(document, mergePlan: mergePlan)
        return ImportResult(
            decksInserted: result.decksInserted,
            decksUpdated: result.decksUpdated,
            cardsInserted: result.cardsInserted,
            cardsUpdated: result.cardsUpdated,
            cardsSkipped: result.cardsSkipped,
            errors: errors + result.errors
        )
    }

    // MARK: - Parsing

    private func parseDocument(from text: String) -> (ImportedDocument, [ImportErrorDetail]) {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var errors: [ImportErrorDetail] = []
        var cards: [ImportedCard] = []

        // Split on newlines; blank lines act as row separators and are skipped.
        let lines = normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
            .filter { !$0.isEmpty }

        // Detect the term/definition separator used in this export.
        // Quizlet default is a tab. Users can customise to " - " via the export panel.
        let termDefSeparator: String = lines.contains(where: { $0.contains("\t") }) ? "\t" : " - "

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1

            let parts = line.components(separatedBy: termDefSeparator)
            guard parts.count >= 2 else {
                errors.append(ImportErrorDetail(
                    line: lineNumber,
                    path: "line[\(index)]",
                    message: "Could not split term from definition (expected \(termDefSeparator.debugDescription) separator)"
                ))
                continue
            }

            let front = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            // Rejoin remaining parts in case the definition itself contains the separator character.
            let back = parts[1...].joined(separator: termDefSeparator).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !front.isEmpty else {
                errors.append(ImportErrorDetail(line: lineNumber, path: "line[\(index)].front", message: "Term is empty"))
                continue
            }
            guard !back.isEmpty else {
                errors.append(ImportErrorDetail(line: lineNumber, path: "line[\(index)].back", message: "Definition is empty"))
                continue
            }

            cards.append(ImportedCard(
                id: UUID(),
                kind: .basic,
                front: front,
                back: back,
                clozeSource: nil,
                choices: [],
                correctChoiceIndex: nil,
                tags: [],
                media: [],
                createdAt: Date(),
                updatedAt: Date(),
                isSuspended: nil,
                srs: nil
            ))
        }

        let deckId = UUID()
        let deck = ImportedDeck(
            id: deckId,
            parentId: nil,
            name: deckName,
            note: nil,
            dueDate: nil,
            dueDateProvided: false,
            isArchived: false,
            cards: cards,
            token: ImportDeckToken(sourceIndex: 0, originalID: deckId)
        )

        return (ImportedDocument(decks: [deck]), errors)
    }
}
