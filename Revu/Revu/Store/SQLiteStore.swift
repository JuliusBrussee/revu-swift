@preconcurrency import Foundation
import SQLite3

private let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor SQLiteStore {
    struct Paths {
        let root: URL
        let database: URL
        let attachments: URL
        let backups: URL
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) var paths: Paths
    private var db: OpaquePointer?
    private var batchDepth: Int = 0

    init(rootURL: URL? = nil) throws {
        self.fileManager = FileManager.default
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let resolvedRoot = try Self.resolveRootURL(rootURL)
        self.paths = try Self.makePaths(root: resolvedRoot)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(paths.database.path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite open error"
            if let handle {
                sqlite3_close(handle)
            }
            throw StorageError.initializationFailed("Failed to open SQLite database: \(message)")
        }

        self.db = opened
        sqlite3_busy_timeout(opened, 5_000)

        try configurePragmas()
        try migrateSchema()
        try migrateLegacyStudyGuidesIfNeeded()

    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Decks

    func allDecks() throws -> [DeckDTO] {
        let sql = """
        SELECT id, parent_id, kind, name, note, due_date, created_at, updated_at, is_archived, course_id, origin_lesson_id
        FROM decks
        ORDER BY name COLLATE NOCASE ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        var results: [DeckDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeDeck(statement))
        }
        return results
    }

    func deck(id: UUID) throws -> DeckDTO? {
        let sql = """
        SELECT id, parent_id, kind, name, note, due_date, created_at, updated_at, is_archived, course_id, origin_lesson_id
        FROM decks
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decodeDeck(statement)
    }

    func upsert(deck: DeckDTO) throws {
        let sql = """
        INSERT INTO decks (
            id, parent_id, kind, name, note, due_date, created_at, updated_at, is_archived, course_id, origin_lesson_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            parent_id = excluded.parent_id,
            kind = excluded.kind,
            name = excluded.name,
            note = excluded.note,
            due_date = excluded.due_date,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            is_archived = excluded.is_archived,
            course_id = excluded.course_id,
            origin_lesson_id = excluded.origin_lesson_id
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(deck.id.uuidString, to: 1, in: statement)
        try bind(deck.parentId?.uuidString, to: 2, in: statement)
        try bind(deck.kind.rawValue, to: 3, in: statement)
        try bind(deck.name, to: 4, in: statement)
        try bind(deck.note, to: 5, in: statement)
        try bind(deck.dueDate?.timeIntervalSince1970, to: 6, in: statement)
        try bind(deck.createdAt.timeIntervalSince1970, to: 7, in: statement)
        try bind(deck.updatedAt.timeIntervalSince1970, to: 8, in: statement)
        try bind(deck.isArchived ? 1 : 0, to: 9, in: statement)
        try bind(deck.courseId?.uuidString, to: 10, in: statement)
        try bind(deck.originLessonId?.uuidString, to: 11, in: statement)

        try stepDone(statement)
    }

    func deleteDeck(id: UUID) throws {
        let sql = "DELETE FROM decks WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Cards

    func allCards() throws -> [CardDTO] {
        let sql = cardSelectSQL(whereClause: nil, orderBy: "ORDER BY c.created_at ASC")
        return try fetchCards(sql: sql, bindings: [])
    }

    func cards(deckId: UUID) throws -> [CardDTO] {
        let sql = cardSelectSQL(whereClause: "c.deck_id = ?", orderBy: "ORDER BY c.created_at ASC")
        return try fetchCards(sql: sql, bindings: [.text(deckId.uuidString)])
    }

    func card(id: UUID) throws -> CardDTO? {
        let sql = cardSelectSQL(whereClause: "c.id = ?", orderBy: "LIMIT 1")
        return try fetchCards(sql: sql, bindings: [.text(id.uuidString)]).first
    }

    func searchCards(text: String, tags: Set<String>, deckId: UUID?) throws -> [CardDTO] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            var base = try (deckId.map(cards(deckId:)) ?? allCards())
            if !tags.isEmpty {
                let lowered = Set(tags.map { $0.lowercased() })
                base = base.filter { !lowered.isDisjoint(with: Set($0.tags.map { $0.lowercased() })) }
            }
            return base
        }

        var clauses: [String] = []
        var bindings: [SQLiteBinding] = []

        clauses.append("f MATCH ?")
        bindings.append(.text(buildFTSQuery(from: trimmed)))

        if let deckId {
            clauses.append("c.deck_id = ?")
            bindings.append(.text(deckId.uuidString))
        }

        let whereClause = clauses.joined(separator: " AND ")
        let sql = cardSelectSQL(
            joinClause: "JOIN cards_fts f ON f.rowid = c.rowid",
            whereClause: whereClause,
            orderBy: "ORDER BY c.updated_at DESC"
        )

        var found: [CardDTO]
        do {
            found = try fetchCards(sql: sql, bindings: bindings)
        } catch {
            // Fallback for malformed token queries.
            let token = "%\(trimmed.lowercased())%"
            var fallbackClauses = ["(lower(c.front) LIKE ? OR lower(c.back) LIKE ? OR lower(c.tags_json) LIKE ?)"]
            var fallbackBindings: [SQLiteBinding] = [.text(token), .text(token), .text(token)]
            if let deckId {
                fallbackClauses.append("c.deck_id = ?")
                fallbackBindings.append(.text(deckId.uuidString))
            }
            let fallbackSQL = cardSelectSQL(whereClause: fallbackClauses.joined(separator: " AND "), orderBy: "ORDER BY c.updated_at DESC")
            found = try fetchCards(sql: fallbackSQL, bindings: fallbackBindings)
        }

        if !tags.isEmpty {
            let lowered = Set(tags.map { $0.lowercased() })
            found = found.filter { !lowered.isDisjoint(with: Set($0.tags.map { $0.lowercased() })) }
        }

        return found
    }

    func upsert(card: CardDTO) throws {
        let cardSQL = """
        INSERT INTO cards (
            id, deck_id, kind, front, back, cloze_source, choices_json, correct_choice_index,
            tags_json, media_json, created_at, updated_at, is_suspended, suspended_by_archive, source_ref
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            deck_id = excluded.deck_id,
            kind = excluded.kind,
            front = excluded.front,
            back = excluded.back,
            cloze_source = excluded.cloze_source,
            choices_json = excluded.choices_json,
            correct_choice_index = excluded.correct_choice_index,
            tags_json = excluded.tags_json,
            media_json = excluded.media_json,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            is_suspended = excluded.is_suspended,
            suspended_by_archive = excluded.suspended_by_archive,
            source_ref = excluded.source_ref
        """

        var cardStatement: OpaquePointer?
        try prepare(cardSQL, into: &cardStatement)
        defer { sqlite3_finalize(cardStatement) }

        try bind(card.id.uuidString, to: 1, in: cardStatement)
        try bind(card.deckId?.uuidString, to: 2, in: cardStatement)
        try bind(card.kind.rawValue, to: 3, in: cardStatement)
        try bind(card.front, to: 4, in: cardStatement)
        try bind(card.back, to: 5, in: cardStatement)
        try bind(card.clozeSource, to: 6, in: cardStatement)
        try bind(jsonString(card.choices), to: 7, in: cardStatement)
        try bind(card.correctChoiceIndex, to: 8, in: cardStatement)
        try bind(jsonString(card.tags), to: 9, in: cardStatement)
        try bind(jsonString(card.media), to: 10, in: cardStatement)
        try bind(card.createdAt.timeIntervalSince1970, to: 11, in: cardStatement)
        try bind(card.updatedAt.timeIntervalSince1970, to: 12, in: cardStatement)
        try bind(card.isSuspended ? 1 : 0, to: 13, in: cardStatement)
        try bind(card.suspendedByArchive ? 1 : 0, to: 14, in: cardStatement)
        try bind(card.sourceRef, to: 15, in: cardStatement)
        try stepDone(cardStatement)

        let srsSQL = """
        INSERT INTO srs_states (
            id, card_id, ease_factor, interval_days, repetitions, lapses, due_date,
            last_reviewed, queue, stability, difficulty, fsrs_reps, last_elapsed_seconds
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(card_id) DO UPDATE SET
            id = excluded.id,
            ease_factor = excluded.ease_factor,
            interval_days = excluded.interval_days,
            repetitions = excluded.repetitions,
            lapses = excluded.lapses,
            due_date = excluded.due_date,
            last_reviewed = excluded.last_reviewed,
            queue = excluded.queue,
            stability = excluded.stability,
            difficulty = excluded.difficulty,
            fsrs_reps = excluded.fsrs_reps,
            last_elapsed_seconds = excluded.last_elapsed_seconds
        """

        var srsStatement: OpaquePointer?
        try prepare(srsSQL, into: &srsStatement)
        defer { sqlite3_finalize(srsStatement) }

        try bind(card.srs.id.uuidString, to: 1, in: srsStatement)
        try bind(card.id.uuidString, to: 2, in: srsStatement)
        try bind(card.srs.easeFactor, to: 3, in: srsStatement)
        try bind(card.srs.interval, to: 4, in: srsStatement)
        try bind(card.srs.repetitions, to: 5, in: srsStatement)
        try bind(card.srs.lapses, to: 6, in: srsStatement)
        try bind(card.srs.dueDate.timeIntervalSince1970, to: 7, in: srsStatement)
        try bind(card.srs.lastReviewed?.timeIntervalSince1970, to: 8, in: srsStatement)
        try bind(card.srs.queue.rawValue, to: 9, in: srsStatement)
        try bind(card.srs.stability, to: 10, in: srsStatement)
        try bind(card.srs.difficulty, to: 11, in: srsStatement)
        try bind(card.srs.fsrsReps, to: 12, in: srsStatement)
        try bind(card.srs.lastElapsedSeconds, to: 13, in: srsStatement)
        try stepDone(srsStatement)
    }

    func deleteCard(id: UUID) throws {
        let sql = "DELETE FROM cards WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    func dueCards(on date: Date, limit: Int?) throws -> [CardDTO] {
        var sql = cardSelectSQL(
            whereClause: "s.due_date <= ? AND c.is_suspended = 0",
            orderBy: "ORDER BY s.due_date ASC"
        )
        if let limit {
            sql += " LIMIT \(max(limit, 0))"
        }
        var cards = try fetchCards(sql: sql, bindings: [.double(date.timeIntervalSince1970)])
        cards = try filterArchived(cards)
        return cards
    }

    func newCards(limit: Int) throws -> [CardDTO] {
        let sql = cardSelectSQL(
            whereClause: "s.queue = ? AND c.is_suspended = 0",
            orderBy: "ORDER BY c.created_at ASC LIMIT ?"
        )
        var cards = try fetchCards(sql: sql, bindings: [.text(SRSStateDTO.Queue.new.rawValue), .int(limit)])
        cards = try filterArchived(cards)
        return cards
    }

    // MARK: - Logs

    func append(log: ReviewLogDTO) throws {
        let sql = """
        INSERT INTO review_logs (
            id, card_id, timestamp, grade, elapsed_ms, prev_interval, next_interval, prev_ease,
            next_ease, prev_stability, next_stability, prev_difficulty, next_difficulty,
            predicted_recall, requested_retention
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(log.id.uuidString, to: 1, in: statement)
        try bind(log.cardId.uuidString, to: 2, in: statement)
        try bind(log.timestamp.timeIntervalSince1970, to: 3, in: statement)
        try bind(log.grade, to: 4, in: statement)
        try bind(log.elapsedMs, to: 5, in: statement)
        try bind(log.prevInterval, to: 6, in: statement)
        try bind(log.nextInterval, to: 7, in: statement)
        try bind(log.prevEase, to: 8, in: statement)
        try bind(log.nextEase, to: 9, in: statement)
        try bind(log.prevStability, to: 10, in: statement)
        try bind(log.nextStability, to: 11, in: statement)
        try bind(log.prevDifficulty, to: 12, in: statement)
        try bind(log.nextDifficulty, to: 13, in: statement)
        try bind(log.predictedRecall, to: 14, in: statement)
        try bind(log.requestedRetention, to: 15, in: statement)
        try stepDone(statement)
    }

    func recentLogs(limit: Int) throws -> [ReviewLogDTO] {
        let sql = """
        SELECT id, card_id, timestamp, grade, elapsed_ms, prev_interval, next_interval, prev_ease,
               next_ease, prev_stability, next_stability, prev_difficulty, next_difficulty,
               predicted_recall, requested_retention
        FROM review_logs
        ORDER BY timestamp DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(limit, to: 1, in: statement)

        var logs: [ReviewLogDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try logs.append(decodeReviewLog(statement))
        }
        return logs
    }

    // MARK: - Study Events

    func append(event: StudyEventDTO) throws {
        let sql = """
        INSERT INTO study_events (
            id, timestamp, session_id, kind, deck_id, card_id, queue_mode, attempt_index,
            concepts_at_time_json, elapsed_ms, grade, predicted_recall_at_start,
            confusion_score, confusion_reasons_json, intervention_kind, intervention_action,
            adaptive_success_rate, adaptive_target_p_success, adaptive_chosen_p_success,
            xp_amount, xp_reason, streak_at_award, celebration_type, threshold, intensity,
            nudge_type, nudge_score, source, cooldown_remaining_sec, nudge_action_value,
            hint_level, entry_point, challenge_mode_action_value, predicted_recall_bucket,
            badge_id, badge_tier, progress_before, progress_after, concept_count, was_successful
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(event.id.uuidString, to: 1, in: statement)
        try bind(event.timestamp.timeIntervalSince1970, to: 2, in: statement)
        try bind(event.sessionId.uuidString, to: 3, in: statement)
        try bind(event.kind.rawValue, to: 4, in: statement)
        try bind(event.deckId?.uuidString, to: 5, in: statement)
        try bind(event.cardId?.uuidString, to: 6, in: statement)
        try bind(event.queueMode, to: 7, in: statement)
        try bind(event.attemptIndex, to: 8, in: statement)
        try bind(optionalJsonString(event.conceptsAtTime), to: 9, in: statement)
        try bind(event.elapsedMs, to: 10, in: statement)
        try bind(event.grade, to: 11, in: statement)
        try bind(event.predictedRecallAtStart, to: 12, in: statement)
        try bind(event.confusionScore, to: 13, in: statement)
        try bind(optionalJsonString(event.confusionReasons), to: 14, in: statement)
        try bind(event.interventionKind, to: 15, in: statement)
        try bind(event.interventionAction, to: 16, in: statement)
        try bind(event.adaptiveSuccessRate, to: 17, in: statement)
        try bind(event.adaptiveTargetPSuccess, to: 18, in: statement)
        try bind(event.adaptiveChosenPSuccess, to: 19, in: statement)
        try bind(event.xpAmount, to: 20, in: statement)
        try bind(event.xpReason, to: 21, in: statement)
        try bind(event.streakAtAward, to: 22, in: statement)
        try bind(event.celebrationType, to: 23, in: statement)
        try bind(event.threshold, to: 24, in: statement)
        try bind(event.intensity, to: 25, in: statement)
        try bind(event.nudgeType, to: 26, in: statement)
        try bind(event.nudgeScore, to: 27, in: statement)
        try bind(event.source, to: 28, in: statement)
        try bind(event.cooldownRemainingSec, to: 29, in: statement)
        try bind(event.nudgeActionValue, to: 30, in: statement)
        try bind(event.hintLevel, to: 31, in: statement)
        try bind(event.entryPoint, to: 32, in: statement)
        try bind(event.challengeModeActionValue, to: 33, in: statement)
        try bind(event.predictedRecallBucket, to: 34, in: statement)
        try bind(event.badgeId, to: 35, in: statement)
        try bind(event.badgeTier, to: 36, in: statement)
        try bind(event.progressBefore, to: 37, in: statement)
        try bind(event.progressAfter, to: 38, in: statement)
        try bind(event.conceptCount, to: 39, in: statement)
        try bind(event.wasSuccessful.map { $0 ? 1 : 0 }, to: 40, in: statement)
        try stepDone(statement)
    }

    func recentEvents(limit: Int) throws -> [StudyEventDTO] {
        let sql = """
        SELECT id, timestamp, session_id, kind, deck_id, card_id, queue_mode, attempt_index,
               concepts_at_time_json, elapsed_ms, grade, predicted_recall_at_start,
               confusion_score, confusion_reasons_json, intervention_kind, intervention_action,
               adaptive_success_rate, adaptive_target_p_success, adaptive_chosen_p_success,
               xp_amount, xp_reason, streak_at_award, celebration_type, threshold, intensity,
               nudge_type, nudge_score, source, cooldown_remaining_sec, nudge_action_value,
               hint_level, entry_point, challenge_mode_action_value, predicted_recall_bucket,
               badge_id, badge_tier, progress_before, progress_after, concept_count, was_successful
        FROM study_events
        ORDER BY timestamp DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(limit, to: 1, in: statement)

        var events: [StudyEventDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try events.append(decodeStudyEvent(statement))
        }
        return events.reversed()
    }

    // MARK: - Settings

    func loadSettings() throws -> UserSettingsDTO? {
        let sql = "SELECT payload_json FROM settings WHERE singleton_key = 1 LIMIT 1"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let payload = columnString(statement, at: 0), let data = payload.data(using: .utf8) else {
            return nil
        }
        return try decoder.decode(UserSettingsDTO.self, from: data)
    }

    func save(settings: UserSettingsDTO) throws {
        let payload = try jsonString(settings)
        let sql = """
        INSERT INTO settings (singleton_key, payload_json)
        VALUES (1, ?)
        ON CONFLICT(singleton_key) DO UPDATE SET payload_json = excluded.payload_json
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(payload, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Exams

    func allExams() throws -> [ExamDTO] {
        let sql = """
        SELECT id, parent_folder_id, title, time_limit, shuffle_questions, created_at, updated_at, course_id, origin_lesson_id
        FROM exams
        ORDER BY title COLLATE NOCASE ASC
        """
        return try fetchExams(sql: sql, bindings: [])
    }

    func exams(parentFolderId: UUID) throws -> [ExamDTO] {
        let sql = """
        SELECT id, parent_folder_id, title, time_limit, shuffle_questions, created_at, updated_at, course_id, origin_lesson_id
        FROM exams
        WHERE parent_folder_id = ?
        ORDER BY title COLLATE NOCASE ASC
        """
        return try fetchExams(sql: sql, bindings: [.text(parentFolderId.uuidString)])
    }

    func exam(id: UUID) throws -> ExamDTO? {
        let sql = """
        SELECT id, parent_folder_id, title, time_limit, shuffle_questions, created_at, updated_at, course_id, origin_lesson_id
        FROM exams
        WHERE id = ?
        LIMIT 1
        """
        return try fetchExams(sql: sql, bindings: [.text(id.uuidString)]).first
    }

    func upsert(exam: ExamDTO) throws {
        let examSQL = """
        INSERT INTO exams (
            id, parent_folder_id, title, time_limit, shuffle_questions, created_at, updated_at, course_id, origin_lesson_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            parent_folder_id = excluded.parent_folder_id,
            title = excluded.title,
            time_limit = excluded.time_limit,
            shuffle_questions = excluded.shuffle_questions,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            course_id = excluded.course_id,
            origin_lesson_id = excluded.origin_lesson_id
        """
        var examStatement: OpaquePointer?
        try prepare(examSQL, into: &examStatement)
        defer { sqlite3_finalize(examStatement) }

        try bind(exam.id.uuidString, to: 1, in: examStatement)
        try bind(exam.parentFolderId?.uuidString, to: 2, in: examStatement)
        try bind(exam.title, to: 3, in: examStatement)
        try bind(exam.config.timeLimit, to: 4, in: examStatement)
        try bind(exam.config.shuffleQuestions ? 1 : 0, to: 5, in: examStatement)
        try bind(exam.createdAt.timeIntervalSince1970, to: 6, in: examStatement)
        try bind(exam.updatedAt.timeIntervalSince1970, to: 7, in: examStatement)
        try bind(exam.courseId?.uuidString, to: 8, in: examStatement)
        try bind(exam.originLessonId?.uuidString, to: 9, in: examStatement)
        try stepDone(examStatement)

        try deleteExamQuestions(examID: exam.id)

        if !exam.questions.isEmpty {
            let questionSQL = """
            INSERT INTO exam_questions (
                id, exam_id, prompt, choices_json, correct_choice_index, sort_order
            ) VALUES (?, ?, ?, ?, ?, ?)
            """
            var questionStatement: OpaquePointer?
            try prepare(questionSQL, into: &questionStatement)
            defer { sqlite3_finalize(questionStatement) }

            for (index, question) in exam.questions.enumerated() {
                sqlite3_reset(questionStatement)
                sqlite3_clear_bindings(questionStatement)

                try bind(question.id.uuidString, to: 1, in: questionStatement)
                try bind(exam.id.uuidString, to: 2, in: questionStatement)
                try bind(question.prompt, to: 3, in: questionStatement)
                try bind(jsonString(question.choices), to: 4, in: questionStatement)
                try bind(question.correctChoiceIndex, to: 5, in: questionStatement)
                try bind(index, to: 6, in: questionStatement)
                try stepDone(questionStatement)
            }
        }
    }

    func deleteExam(id: UUID) throws {
        let sql = "DELETE FROM exams WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Study Guides

    func allStudyGuides() throws -> [StudyGuideDTO] {
        let sql = """
        SELECT id, parent_folder_id, title, markdown_content, tags_json, created_at, last_edited_at, course_id, origin_lesson_id
        FROM study_guides
        ORDER BY title COLLATE NOCASE ASC
        """
        return try fetchStudyGuides(sql: sql, bindings: [])
    }

    func studyGuides(parentFolderId: UUID) throws -> [StudyGuideDTO] {
        let sql = """
        SELECT id, parent_folder_id, title, markdown_content, tags_json, created_at, last_edited_at, course_id, origin_lesson_id
        FROM study_guides
        WHERE parent_folder_id = ?
        ORDER BY title COLLATE NOCASE ASC
        """
        return try fetchStudyGuides(sql: sql, bindings: [.text(parentFolderId.uuidString)])
    }

    func searchStudyGuides(query: String, parentFolderId: UUID?) throws -> [StudyGuideDTO] {
        let token = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty {
            if let parentFolderId {
                return try studyGuides(parentFolderId: parentFolderId)
            }
            return try allStudyGuides()
        }

        var clauses: [String] = ["f MATCH ?"]
        var bindings: [SQLiteBinding] = [.text(buildFTSQuery(from: token))]

        if let parentFolderId {
            clauses.append("g.parent_folder_id = ?")
            bindings.append(.text(parentFolderId.uuidString))
        }

        let sql = """
        SELECT DISTINCT g.id, g.parent_folder_id, g.title, g.markdown_content, g.tags_json, g.created_at, g.last_edited_at, g.course_id, g.origin_lesson_id
        FROM study_guides g
        JOIN study_guides_fts f ON f.rowid = g.rowid
        LEFT JOIN study_guide_attachments a ON a.study_guide_id = g.id
        WHERE \(clauses.joined(separator: " AND "))
           OR lower(a.filename) LIKE ?
        ORDER BY g.title COLLATE NOCASE ASC
        """

        var attachmentsLike = "%\(token.lowercased())%"
        if parentFolderId != nil {
            attachmentsLike = "%\(token.lowercased())%"
        }
        bindings.append(.text(attachmentsLike))

        do {
            return try fetchStudyGuides(sql: sql, bindings: bindings)
        } catch {
            var fallback = try (parentFolderId.map(studyGuides(parentFolderId:)) ?? allStudyGuides())
            let lowered = token.lowercased()
            fallback = fallback.filter { guide in
                if guide.title.lowercased().contains(lowered) { return true }
                if guide.markdownContent.lowercased().contains(lowered) { return true }
                if guide.tags.contains(where: { $0.lowercased().contains(lowered) }) { return true }
                if guide.attachments.contains(where: { $0.filename.lowercased().contains(lowered) }) { return true }
                return false
            }
            return fallback
        }
    }

    func studyGuide(id: UUID) throws -> StudyGuideDTO? {
        let sql = """
        SELECT id, parent_folder_id, title, markdown_content, tags_json, created_at, last_edited_at, course_id, origin_lesson_id
        FROM study_guides
        WHERE id = ?
        LIMIT 1
        """
        return try fetchStudyGuides(sql: sql, bindings: [.text(id.uuidString)]).first
    }

    func upsert(studyGuide: StudyGuideDTO) throws {
        let guideSQL = """
        INSERT INTO study_guides (
            id, parent_folder_id, title, markdown_content, tags_json, created_at, last_edited_at, course_id, origin_lesson_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            parent_folder_id = excluded.parent_folder_id,
            title = excluded.title,
            markdown_content = excluded.markdown_content,
            tags_json = excluded.tags_json,
            created_at = excluded.created_at,
            last_edited_at = excluded.last_edited_at,
            course_id = excluded.course_id,
            origin_lesson_id = excluded.origin_lesson_id
        """

        var guideStatement: OpaquePointer?
        try prepare(guideSQL, into: &guideStatement)
        defer { sqlite3_finalize(guideStatement) }

        try bind(studyGuide.id.uuidString, to: 1, in: guideStatement)
        try bind(studyGuide.parentFolderId?.uuidString, to: 2, in: guideStatement)
        try bind(studyGuide.title, to: 3, in: guideStatement)
        try bind(studyGuide.markdownContent, to: 4, in: guideStatement)
        try bind(jsonString(studyGuide.tags), to: 5, in: guideStatement)
        try bind(studyGuide.createdAt.timeIntervalSince1970, to: 6, in: guideStatement)
        try bind(studyGuide.lastEditedAt.timeIntervalSince1970, to: 7, in: guideStatement)
        try bind(studyGuide.courseId?.uuidString, to: 8, in: guideStatement)
        try bind(studyGuide.originLessonId?.uuidString, to: 9, in: guideStatement)
        try stepDone(guideStatement)

        try deleteStudyGuideAttachments(studyGuideID: studyGuide.id)

        if !studyGuide.attachments.isEmpty {
            let attachmentSQL = """
            INSERT INTO study_guide_attachments (
                id, study_guide_id, filename, relative_path, mime_type, size_bytes, created_at, sort_order
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var attachmentStatement: OpaquePointer?
            try prepare(attachmentSQL, into: &attachmentStatement)
            defer { sqlite3_finalize(attachmentStatement) }

            for (index, attachment) in studyGuide.attachments.enumerated() {
                sqlite3_reset(attachmentStatement)
                sqlite3_clear_bindings(attachmentStatement)

                try bind(attachment.id.uuidString, to: 1, in: attachmentStatement)
                try bind(studyGuide.id.uuidString, to: 2, in: attachmentStatement)
                try bind(attachment.filename, to: 3, in: attachmentStatement)
                try bind(attachment.relativePath, to: 4, in: attachmentStatement)
                try bind(attachment.mimeType, to: 5, in: attachmentStatement)
                try bind(Int64(attachment.sizeBytes), to: 6, in: attachmentStatement)
                try bind(attachment.createdAt.timeIntervalSince1970, to: 7, in: attachmentStatement)
                try bind(index, to: 8, in: attachmentStatement)
                try stepDone(attachmentStatement)
            }
        }
    }

    func deleteStudyGuide(id: UUID) throws {
        let sql = "DELETE FROM study_guides WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Courses

    func allCourses() throws -> [CourseDTO] {
        let sql = """
        SELECT id, name, course_code, exam_date, weekly_time_budget_minutes, color_hex, created_at, updated_at
        FROM courses
        ORDER BY name COLLATE NOCASE ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        var results: [CourseDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeCourse(statement))
        }
        return results
    }

    func course(id: UUID) throws -> CourseDTO? {
        let sql = """
        SELECT id, name, course_code, exam_date, weekly_time_budget_minutes, color_hex, created_at, updated_at
        FROM courses
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decodeCourse(statement)
    }

    func upsert(course: CourseDTO) throws {
        let sql = """
        INSERT INTO courses (
            id, name, course_code, exam_date, weekly_time_budget_minutes, color_hex, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            course_code = excluded.course_code,
            exam_date = excluded.exam_date,
            weekly_time_budget_minutes = excluded.weekly_time_budget_minutes,
            color_hex = excluded.color_hex,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(course.id.uuidString, to: 1, in: statement)
        try bind(course.name, to: 2, in: statement)
        try bind(course.courseCode, to: 3, in: statement)
        try bind(course.examDate?.timeIntervalSince1970, to: 4, in: statement)
        try bind(course.weeklyTimeBudgetMinutes, to: 5, in: statement)
        try bind(course.colorHex, to: 6, in: statement)
        try bind(course.createdAt.timeIntervalSince1970, to: 7, in: statement)
        try bind(course.updatedAt.timeIntervalSince1970, to: 8, in: statement)

        try stepDone(statement)
    }

    func deleteCourse(id: UUID) throws {
        let sql = "DELETE FROM courses WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Course Topics

    func allTopics() throws -> [CourseTopicDTO] {
        let sql = """
        SELECT id, course_id, name, sort_order, source_description
        FROM course_topics
        ORDER BY sort_order ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        var results: [CourseTopicDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeTopic(statement))
        }
        return results
    }

    func topics(courseId: UUID) throws -> [CourseTopicDTO] {
        let sql = """
        SELECT id, course_id, name, sort_order, source_description
        FROM course_topics
        WHERE course_id = ?
        ORDER BY sort_order ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(courseId.uuidString, to: 1, in: statement)

        var results: [CourseTopicDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeTopic(statement))
        }
        return results
    }

    func topic(id: UUID) throws -> CourseTopicDTO? {
        let sql = """
        SELECT id, course_id, name, sort_order, source_description
        FROM course_topics
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decodeTopic(statement)
    }

    func upsert(topic: CourseTopicDTO) throws {
        let sql = """
        INSERT INTO course_topics (
            id, course_id, name, sort_order, source_description
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            course_id = excluded.course_id,
            name = excluded.name,
            sort_order = excluded.sort_order,
            source_description = excluded.source_description
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(topic.id.uuidString, to: 1, in: statement)
        try bind(topic.courseId.uuidString, to: 2, in: statement)
        try bind(topic.name, to: 3, in: statement)
        try bind(topic.sortOrder, to: 4, in: statement)
        try bind(topic.sourceDescription, to: 5, in: statement)

        try stepDone(statement)
    }

    func deleteTopic(id: UUID) throws {
        let sql = "DELETE FROM course_topics WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Lessons

    func allLessons() throws -> [LessonDTO] {
        let sql = """
        SELECT id, course_id, title, summary, created_at, updated_at, source_type, status
        FROM lessons
        ORDER BY created_at ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        var results: [LessonDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeLesson(statement))
        }
        return results
    }

    func lessons(courseId: UUID) throws -> [LessonDTO] {
        let sql = """
        SELECT id, course_id, title, summary, created_at, updated_at, source_type, status
        FROM lessons
        WHERE course_id = ?
        ORDER BY created_at ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(courseId.uuidString, to: 1, in: statement)

        var results: [LessonDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeLesson(statement))
        }
        return results
    }

    func lesson(id: UUID) throws -> LessonDTO? {
        let sql = """
        SELECT id, course_id, title, summary, created_at, updated_at, source_type, status
        FROM lessons
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decodeLesson(statement)
    }

    func upsert(lesson: LessonDTO) throws {
        let sql = """
        INSERT INTO lessons (
            id, course_id, title, summary, created_at, updated_at, source_type, status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            course_id = excluded.course_id,
            title = excluded.title,
            summary = excluded.summary,
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            source_type = excluded.source_type,
            status = excluded.status
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(lesson.id.uuidString, to: 1, in: statement)
        try bind(lesson.courseId.uuidString, to: 2, in: statement)
        try bind(lesson.title, to: 3, in: statement)
        try bind(lesson.summary, to: 4, in: statement)
        try bind(lesson.createdAt.timeIntervalSince1970, to: 5, in: statement)
        try bind(lesson.updatedAt.timeIntervalSince1970, to: 6, in: statement)
        try bind(lesson.sourceType.rawValue, to: 7, in: statement)
        try bind(lesson.status.rawValue, to: 8, in: statement)
        try stepDone(statement)
    }

    func deleteLesson(id: UUID) throws {
        let sql = "DELETE FROM lessons WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Course Materials

    func allMaterials() throws -> [CourseMaterialDTO] {
        let sql = """
        SELECT id, course_id, topic_id, lesson_id, filename, file_type, extracted_text, word_count, processing_status, processing_error, processed_at, imported_at
        FROM course_materials
        ORDER BY imported_at ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        var results: [CourseMaterialDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeMaterial(statement))
        }
        return results
    }

    func materials(courseId: UUID) throws -> [CourseMaterialDTO] {
        let sql = """
        SELECT id, course_id, topic_id, lesson_id, filename, file_type, extracted_text, word_count, processing_status, processing_error, processed_at, imported_at
        FROM course_materials
        WHERE course_id = ?
        ORDER BY imported_at ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(courseId.uuidString, to: 1, in: statement)

        var results: [CourseMaterialDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            try results.append(decodeMaterial(statement))
        }
        return results
    }

    func material(id: UUID) throws -> CourseMaterialDTO? {
        let sql = """
        SELECT id, course_id, topic_id, lesson_id, filename, file_type, extracted_text, word_count, processing_status, processing_error, processed_at, imported_at
        FROM course_materials
        WHERE id = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return try decodeMaterial(statement)
    }

    func upsert(material: CourseMaterialDTO) throws {
        let sql = """
        INSERT INTO course_materials (
            id, course_id, topic_id, lesson_id, filename, file_type, extracted_text, word_count, processing_status, processing_error, processed_at, imported_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            course_id = excluded.course_id,
            topic_id = excluded.topic_id,
            lesson_id = excluded.lesson_id,
            filename = excluded.filename,
            file_type = excluded.file_type,
            extracted_text = excluded.extracted_text,
            word_count = excluded.word_count,
            processing_status = excluded.processing_status,
            processing_error = excluded.processing_error,
            processed_at = excluded.processed_at,
            imported_at = excluded.imported_at
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(material.id.uuidString, to: 1, in: statement)
        try bind(material.courseId.uuidString, to: 2, in: statement)
        try bind(material.topicId?.uuidString, to: 3, in: statement)
        try bind(material.lessonId?.uuidString, to: 4, in: statement)
        try bind(material.filename, to: 5, in: statement)
        try bind(material.fileType, to: 6, in: statement)
        try bind(material.extractedText, to: 7, in: statement)
        try bind(material.wordCount, to: 8, in: statement)
        try bind(material.processingStatus.rawValue, to: 9, in: statement)
        try bind(material.processingError, to: 10, in: statement)
        try bind(material.processedAt?.timeIntervalSince1970, to: 11, in: statement)
        try bind(material.importedAt.timeIntervalSince1970, to: 12, in: statement)

        try stepDone(statement)
    }

    func deleteMaterial(id: UUID) throws {
        let sql = "DELETE FROM course_materials WHERE id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Lesson Generation Jobs

    func lessonGenerationJobs(lessonId: UUID) throws -> [LessonGenerationJobDTO] {
        let sql = """
        SELECT id, lesson_id, artifact_kind, status, item_count, error_message, started_at, updated_at
        FROM lesson_generation_jobs
        WHERE lesson_id = ?
        ORDER BY updated_at DESC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(lessonId.uuidString, to: 1, in: statement)

        var results: [LessonGenerationJobDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = columnString(statement, at: 0), let id = UUID(uuidString: idString) else { continue }
            guard let lessonIdString = columnString(statement, at: 1), let lessonId = UUID(uuidString: lessonIdString) else { continue }
            let kindRaw = columnString(statement, at: 2) ?? LessonArtifactKind.notes.rawValue
            let statusRaw = columnString(statement, at: 3) ?? ArtifactStatus.notStarted.rawValue
            let kind = LessonArtifactKind(rawValue: kindRaw) ?? .notes
            let status = ArtifactStatus(rawValue: statusRaw) ?? .notStarted
            let itemCount = Int(columnInt(statement, at: 4))
            let errorMessage = columnString(statement, at: 5)
            let startedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 6))
            let updatedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 7))

            results.append(
                LessonGenerationJobDTO(
                    id: id,
                    lessonId: lessonId,
                    kind: kind,
                    status: status,
                    itemCount: itemCount,
                    errorMessage: errorMessage,
                    startedAt: startedAt,
                    updatedAt: updatedAt
                )
            )
        }
        return results
    }

    func upsert(lessonGenerationJob: LessonGenerationJobDTO) throws {
        let sql = """
        INSERT INTO lesson_generation_jobs (
            id, lesson_id, artifact_kind, status, item_count, error_message, started_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            lesson_id = excluded.lesson_id,
            artifact_kind = excluded.artifact_kind,
            status = excluded.status,
            item_count = excluded.item_count,
            error_message = excluded.error_message,
            started_at = excluded.started_at,
            updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(lessonGenerationJob.id.uuidString, to: 1, in: statement)
        try bind(lessonGenerationJob.lessonId.uuidString, to: 2, in: statement)
        try bind(lessonGenerationJob.kind.rawValue, to: 3, in: statement)
        try bind(lessonGenerationJob.status.rawValue, to: 4, in: statement)
        try bind(lessonGenerationJob.itemCount, to: 5, in: statement)
        try bind(lessonGenerationJob.errorMessage, to: 6, in: statement)
        try bind(lessonGenerationJob.startedAt.timeIntervalSince1970, to: 7, in: statement)
        try bind(lessonGenerationJob.updatedAt.timeIntervalSince1970, to: 8, in: statement)
        try stepDone(statement)
    }

    func deleteLessonGenerationJobs(lessonId: UUID) throws {
        let sql = "DELETE FROM lesson_generation_jobs WHERE lesson_id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(lessonId.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Concept States

    func allConceptStates() throws -> [ConceptState] {
        let sql = """
        SELECT key, display_name, p_known, attempts, corrects, updated_at
        FROM concept_states
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        var states: [ConceptState] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            states.append(
                ConceptState(
                    key: columnString(statement, at: 0) ?? "",
                    displayName: columnString(statement, at: 1) ?? "",
                    pKnown: columnDouble(statement, at: 2),
                    attempts: Int(columnInt(statement, at: 3)),
                    corrects: Int(columnInt(statement, at: 4)),
                    updatedAt: Date(timeIntervalSince1970: columnDouble(statement, at: 5))
                )
            )
        }
        return states
    }

    func conceptState(forKey key: String) throws -> ConceptState? {
        let sql = """
        SELECT key, display_name, p_known, attempts, corrects, updated_at
        FROM concept_states
        WHERE key = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(key, to: 1, in: statement)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ConceptState(
            key: columnString(statement, at: 0) ?? key,
            displayName: columnString(statement, at: 1) ?? key,
            pKnown: columnDouble(statement, at: 2),
            attempts: Int(columnInt(statement, at: 3)),
            corrects: Int(columnInt(statement, at: 4)),
            updatedAt: Date(timeIntervalSince1970: columnDouble(statement, at: 5))
        )
    }

    func upsert(conceptState: ConceptState) throws {
        let sql = """
        INSERT INTO concept_states (key, display_name, p_known, attempts, corrects, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            display_name = excluded.display_name,
            p_known = excluded.p_known,
            attempts = excluded.attempts,
            corrects = excluded.corrects,
            updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(conceptState.key, to: 1, in: statement)
        try bind(conceptState.displayName, to: 2, in: statement)
        try bind(conceptState.pKnown, to: 3, in: statement)
        try bind(conceptState.attempts, to: 4, in: statement)
        try bind(conceptState.corrects, to: 5, in: statement)
        try bind(conceptState.updatedAt.timeIntervalSince1970, to: 6, in: statement)
        try stepDone(statement)
    }

    // MARK: - Content Chunks

    func allChunks(courseId: UUID) throws -> [ContentChunk] {
        let sql = """
        SELECT id, material_id, course_id, source_filename, source_page, section_heading, content, word_count, concept_keys, created_at
        FROM content_chunks
        WHERE course_id = ?
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(courseId.uuidString, to: 1, in: statement)

        var chunks: [ContentChunk] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            chunks.append(decodeChunk(statement))
        }
        return chunks
    }

    func searchChunks(courseId: UUID, keywords: [String], limit: Int = 5) throws -> [ContentChunk] {
        let allChunks = try allChunks(courseId: courseId)
        let normalizedKeywords = keywords.map { $0.lowercased() }

        let scored = allChunks.map { chunk -> (chunk: ContentChunk, score: Double) in
            let text = chunk.content.lowercased()
            var score: Double = 0

            // Exact concept key match (highest weight)
            for key in chunk.conceptKeys {
                if normalizedKeywords.contains(key.lowercased()) {
                    score += 3.0
                }
            }

            // Heading match (medium weight)
            if let heading = chunk.sectionHeading?.lowercased() {
                for keyword in normalizedKeywords {
                    if heading.contains(keyword) { score += 2.0 }
                }
            }

            // Content keyword match (lower weight, density-based)
            for keyword in normalizedKeywords {
                let occurrences = text.components(separatedBy: keyword).count - 1
                score += min(Double(occurrences) * 0.5, 2.0)
            }

            return (chunk, score)
        }

        return scored
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.chunk)
    }

    func upsert(chunk: ContentChunk) throws {
        let sql = """
        INSERT INTO content_chunks (id, material_id, course_id, source_filename, source_page, section_heading, content, word_count, concept_keys, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            material_id = excluded.material_id,
            course_id = excluded.course_id,
            source_filename = excluded.source_filename,
            source_page = excluded.source_page,
            section_heading = excluded.section_heading,
            content = excluded.content,
            word_count = excluded.word_count,
            concept_keys = excluded.concept_keys,
            created_at = excluded.created_at
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(chunk.id.uuidString, to: 1, in: statement)
        try bind(chunk.materialId?.uuidString, to: 2, in: statement)
        try bind(chunk.courseId?.uuidString, to: 3, in: statement)
        try bind(chunk.sourceFilename, to: 4, in: statement)
        try bind(chunk.sourcePage, to: 5, in: statement)
        try bind(chunk.sectionHeading, to: 6, in: statement)
        try bind(chunk.content, to: 7, in: statement)
        try bind(chunk.wordCount, to: 8, in: statement)
        try bind(chunk.conceptKeys.joined(separator: ","), to: 9, in: statement)
        try bind(chunk.createdAt.timeIntervalSince1970, to: 10, in: statement)
        try stepDone(statement)
    }

    func deleteChunks(courseId: UUID) throws {
        let sql = "DELETE FROM content_chunks WHERE course_id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(courseId.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    private func decodeChunk(_ statement: OpaquePointer?) -> ContentChunk {
        let id = columnString(statement, at: 0).flatMap(UUID.init(uuidString:)) ?? UUID()
        let materialId = columnString(statement, at: 1).flatMap(UUID.init(uuidString:))
        let courseId = columnString(statement, at: 2).flatMap(UUID.init(uuidString:))
        let sourceFilename = columnString(statement, at: 3) ?? ""
        let sourcePage = columnOptionalInt(statement, at: 4)
        let sectionHeading = columnString(statement, at: 5)
        let content = columnString(statement, at: 6) ?? ""
        let wordCount = Int(columnInt(statement, at: 7))
        let conceptKeysRaw = columnString(statement, at: 8) ?? ""
        let conceptKeys = conceptKeysRaw.isEmpty ? [] : conceptKeysRaw.components(separatedBy: ",")
        let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 9))

        return ContentChunk(
            id: id,
            materialId: materialId,
            courseId: courseId,
            sourceFilename: sourceFilename,
            sourcePage: sourcePage,
            sectionHeading: sectionHeading,
            content: content,
            wordCount: wordCount,
            conceptKeys: conceptKeys,
            createdAt: createdAt
        )
    }

    // MARK: - Sync State

    func enqueueMutation(_ mutation: SyncMutation) throws {
        let sql = """
        INSERT INTO sync_outbox (
            id, client_mutation_id, entity, entity_id, operation, payload, base_server_version, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(client_mutation_id) DO NOTHING
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }

        try bind(mutation.id.uuidString, to: 1, in: statement)
        try bind(mutation.clientMutationID, to: 2, in: statement)
        try bind(mutation.entity, to: 3, in: statement)
        try bind(mutation.entityID, to: 4, in: statement)
        try bind(mutation.operation.rawValue, to: 5, in: statement)
        try bind(mutation.payload, to: 6, in: statement)
        try bind(mutation.baseServerVersion, to: 7, in: statement)
        try bind(mutation.createdAt.timeIntervalSince1970, to: 8, in: statement)
        try stepDone(statement)
    }

    func pendingMutations(limit: Int) throws -> [SyncMutation] {
        let sql = """
        SELECT id, client_mutation_id, entity, entity_id, operation, payload, base_server_version, created_at
        FROM sync_outbox
        ORDER BY created_at ASC
        LIMIT ?
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(limit, to: 1, in: statement)

        var mutations: [SyncMutation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idString = columnString(statement, at: 0),
                let id = UUID(uuidString: idString),
                let clientMutationID = columnString(statement, at: 1),
                let entity = columnString(statement, at: 2),
                let entityID = columnString(statement, at: 3),
                let opRaw = columnString(statement, at: 4),
                let op = SyncMutationOperation(rawValue: opRaw)
            else {
                continue
            }

            let payload = columnData(statement, at: 5)
            let baseVersion = columnOptionalInt64(statement, at: 6)
            let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 7))
            mutations.append(
                SyncMutation(
                    id: id,
                    clientMutationID: clientMutationID,
                    entity: entity,
                    entityID: entityID,
                    operation: op,
                    payload: payload,
                    baseServerVersion: baseVersion,
                    createdAt: createdAt
                )
            )
        }

        return mutations
    }

    func markMutationSynced(clientMutationID: String) throws {
        let sql = "DELETE FROM sync_outbox WHERE client_mutation_id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(clientMutationID, to: 1, in: statement)
        try stepDone(statement)
    }

    func syncCursor() throws -> Int64 {
        let sql = "SELECT int_value FROM sync_state WHERE state_key = 'cursor_seq' LIMIT 1"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return columnInt64(statement, at: 0)
    }

    func setSyncCursor(_ cursor: Int64) throws {
        let sql = """
        INSERT INTO sync_state (state_key, int_value)
        VALUES ('cursor_seq', ?)
        ON CONFLICT(state_key) DO UPDATE SET int_value = excluded.int_value
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(cursor, to: 1, in: statement)
        try stepDone(statement)
    }

    // MARK: - Utility

    func tagsSnapshot() throws -> [String] {
        let cards = try allCards()
        var displayByKey: [String: String] = [:]
        for card in cards {
            for tag in card.tags {
                let key = tag.lowercased()
                if displayByKey[key] == nil {
                    displayByKey[key] = tag
                }
            }
        }
        return displayByKey.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func wipeAllData() throws {
        let tables = [
            "conversation_messages",
            "conversations",
            "sync_outbox",
            "sync_state",
            "study_guide_attachments",
            "study_guides",
            "exam_questions",
            "exams",
            "content_chunks",
            "lesson_generation_jobs",
            "course_materials",
            "lessons",
            "course_topics",
            "courses",
            "study_events",
            "review_logs",
            "concept_states",
            "srs_states",
            "cards",
            "settings",
            "decks"
        ]

        try execute("PRAGMA foreign_keys = OFF")
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            for table in tables {
                try execute("DELETE FROM \(table)")
            }
            try execute("COMMIT")
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            try? execute("ROLLBACK")
            try? execute("PRAGMA foreign_keys = ON")
            throw error
        }

        try clearDirectory(paths.attachments)
        try clearDirectory(paths.backups)
    }

    func beginBatch() throws {
        if batchDepth == 0 {
            try execute("BEGIN IMMEDIATE TRANSACTION")
        }
        batchDepth += 1
    }

    func endBatch() throws {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        if batchDepth == 0 {
            try execute("COMMIT")
        }
    }

    func rollbackBatch() {
        batchDepth = 0
        try? execute("ROLLBACK")
    }

    // MARK: - Private SQL helpers

    private func configurePragmas() throws {
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA temp_store=MEMORY")
    }

    private func migrateSchema() throws {
        let statements: [String] = [
            """
            CREATE TABLE IF NOT EXISTS decks (
                id TEXT PRIMARY KEY,
                parent_id TEXT REFERENCES decks(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                note TEXT,
                due_date REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_archived INTEGER NOT NULL DEFAULT 0,
                course_id TEXT REFERENCES courses(id) ON DELETE SET NULL,
                origin_lesson_id TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_decks_parent_id ON decks(parent_id)",
            "CREATE INDEX IF NOT EXISTS idx_decks_name ON decks(name)",
            """
            CREATE TABLE IF NOT EXISTS cards (
                id TEXT PRIMARY KEY,
                deck_id TEXT REFERENCES decks(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                front TEXT NOT NULL,
                back TEXT NOT NULL,
                cloze_source TEXT,
                choices_json TEXT NOT NULL,
                correct_choice_index INTEGER,
                tags_json TEXT NOT NULL,
                media_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_suspended INTEGER NOT NULL,
                suspended_by_archive INTEGER NOT NULL DEFAULT 0,
                source_ref TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_cards_deck_id ON cards(deck_id)",
            "CREATE INDEX IF NOT EXISTS idx_cards_updated_at ON cards(updated_at)",
            "CREATE INDEX IF NOT EXISTS idx_cards_created_at ON cards(created_at)",
            """
            CREATE TABLE IF NOT EXISTS srs_states (
                id TEXT PRIMARY KEY,
                card_id TEXT NOT NULL UNIQUE REFERENCES cards(id) ON DELETE CASCADE,
                ease_factor REAL NOT NULL,
                interval_days INTEGER NOT NULL,
                repetitions INTEGER NOT NULL,
                lapses INTEGER NOT NULL,
                due_date REAL NOT NULL,
                last_reviewed REAL,
                queue TEXT NOT NULL,
                stability REAL NOT NULL,
                difficulty REAL NOT NULL,
                fsrs_reps INTEGER NOT NULL,
                last_elapsed_seconds REAL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_srs_due_date ON srs_states(due_date)",
            "CREATE INDEX IF NOT EXISTS idx_srs_queue ON srs_states(queue)",
            """
            CREATE TABLE IF NOT EXISTS review_logs (
                id TEXT PRIMARY KEY,
                card_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                grade INTEGER NOT NULL,
                elapsed_ms INTEGER NOT NULL,
                prev_interval INTEGER NOT NULL,
                next_interval INTEGER NOT NULL,
                prev_ease REAL NOT NULL,
                next_ease REAL NOT NULL,
                prev_stability REAL NOT NULL,
                next_stability REAL NOT NULL,
                prev_difficulty REAL NOT NULL,
                next_difficulty REAL NOT NULL,
                predicted_recall REAL NOT NULL,
                requested_retention REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_review_logs_timestamp ON review_logs(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_review_logs_card_id ON review_logs(card_id)",
            """
            CREATE TABLE IF NOT EXISTS study_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                session_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                deck_id TEXT,
                card_id TEXT,
                queue_mode TEXT,
                attempt_index INTEGER,
                concepts_at_time_json TEXT,
                elapsed_ms INTEGER,
                grade INTEGER,
                predicted_recall_at_start REAL,
                confusion_score REAL,
                confusion_reasons_json TEXT,
                intervention_kind TEXT,
                intervention_action TEXT,
                adaptive_success_rate REAL,
                adaptive_target_p_success REAL,
                adaptive_chosen_p_success REAL,
                xp_amount INTEGER,
                xp_reason TEXT,
                streak_at_award INTEGER,
                celebration_type TEXT,
                threshold INTEGER,
                intensity TEXT,
                nudge_type TEXT,
                nudge_score REAL,
                source TEXT,
                cooldown_remaining_sec INTEGER,
                nudge_action_value TEXT,
                hint_level INTEGER,
                entry_point TEXT,
                challenge_mode_action_value TEXT,
                predicted_recall_bucket TEXT,
                badge_id TEXT,
                badge_tier TEXT,
                progress_before REAL,
                progress_after REAL,
                concept_count INTEGER,
                was_successful INTEGER
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_study_events_timestamp ON study_events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_study_events_session_id ON study_events(session_id)",
            """
            CREATE TABLE IF NOT EXISTS exams (
                id TEXT PRIMARY KEY,
                parent_folder_id TEXT,
                title TEXT NOT NULL,
                time_limit INTEGER,
                shuffle_questions INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                course_id TEXT REFERENCES courses(id) ON DELETE SET NULL,
                origin_lesson_id TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_exams_parent_folder_id ON exams(parent_folder_id)",
            """
            CREATE TABLE IF NOT EXISTS exam_questions (
                id TEXT PRIMARY KEY,
                exam_id TEXT NOT NULL REFERENCES exams(id) ON DELETE CASCADE,
                prompt TEXT NOT NULL,
                choices_json TEXT NOT NULL,
                correct_choice_index INTEGER NOT NULL,
                sort_order INTEGER NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_exam_questions_exam_id_sort ON exam_questions(exam_id, sort_order)",
            """
            CREATE TABLE IF NOT EXISTS study_guides (
                id TEXT PRIMARY KEY,
                parent_folder_id TEXT,
                title TEXT NOT NULL,
                markdown_content TEXT NOT NULL,
                tags_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                last_edited_at REAL NOT NULL,
                course_id TEXT REFERENCES courses(id) ON DELETE SET NULL,
                origin_lesson_id TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_study_guides_parent_folder_id ON study_guides(parent_folder_id)",
            """
            CREATE TABLE IF NOT EXISTS study_guide_attachments (
                id TEXT PRIMARY KEY,
                study_guide_id TEXT NOT NULL REFERENCES study_guides(id) ON DELETE CASCADE,
                filename TEXT NOT NULL,
                relative_path TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                created_at REAL NOT NULL,
                sort_order INTEGER NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_study_guide_attachments_guide_id_sort ON study_guide_attachments(study_guide_id, sort_order)",
            """
            CREATE TABLE IF NOT EXISTS concept_states (
                key TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                p_known REAL NOT NULL,
                attempts INTEGER NOT NULL,
                corrects INTEGER NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS settings (
                singleton_key INTEGER PRIMARY KEY CHECK(singleton_key = 1),
                payload_json TEXT NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS conversations (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                is_pinned INTEGER NOT NULL DEFAULT 0,
                payload_json TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_conversations_updated_at ON conversations(updated_at)",
            """
            CREATE TABLE IF NOT EXISTS conversation_messages (
                id TEXT PRIMARY KEY,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp REAL NOT NULL,
                reaction TEXT,
                sort_order INTEGER NOT NULL,
                payload_json TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_conversation_messages_conversation_sort ON conversation_messages(conversation_id, sort_order)",
            """
            CREATE TABLE IF NOT EXISTS sync_outbox (
                id TEXT PRIMARY KEY,
                client_mutation_id TEXT NOT NULL UNIQUE,
                entity TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                operation TEXT NOT NULL,
                payload BLOB,
                base_server_version INTEGER,
                created_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_sync_outbox_created_at ON sync_outbox(created_at)",
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                state_key TEXT PRIMARY KEY,
                int_value INTEGER
            )
            """,
            "CREATE VIEW IF NOT EXISTS cards_search_source AS SELECT rowid, id AS card_id, front, back, tags_json AS tags FROM cards",
            "CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(card_id UNINDEXED, front, back, tags, content='cards_search_source', content_rowid='rowid')",
            "CREATE VIEW IF NOT EXISTS study_guides_search_source AS SELECT rowid, id AS guide_id, title, markdown_content, tags_json AS tags FROM study_guides",
            "CREATE VIRTUAL TABLE IF NOT EXISTS study_guides_fts USING fts5(guide_id UNINDEXED, title, markdown_content, tags, content='study_guides_search_source', content_rowid='rowid')",
            """
            CREATE TABLE IF NOT EXISTS courses (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                course_code TEXT,
                exam_date REAL,
                weekly_time_budget_minutes INTEGER,
                color_hex TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_courses_name ON courses(name)",
            """
            CREATE TABLE IF NOT EXISTS course_topics (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL DEFAULT 0,
                source_description TEXT
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_course_topics_course_id ON course_topics(course_id)",
            """
            CREATE TABLE IF NOT EXISTS lessons (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
                title TEXT NOT NULL,
                summary TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                source_type TEXT NOT NULL DEFAULT 'upload',
                status TEXT NOT NULL DEFAULT 'ready'
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_lessons_course_id ON lessons(course_id)",
            """
            CREATE TABLE IF NOT EXISTS lesson_generation_jobs (
                id TEXT PRIMARY KEY,
                lesson_id TEXT NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
                artifact_kind TEXT NOT NULL,
                status TEXT NOT NULL,
                item_count INTEGER NOT NULL DEFAULT 0,
                error_message TEXT,
                started_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_lesson_generation_jobs_lesson_kind ON lesson_generation_jobs(lesson_id, artifact_kind, updated_at DESC)",
            """
            CREATE TABLE IF NOT EXISTS course_materials (
                id TEXT PRIMARY KEY,
                course_id TEXT NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
                topic_id TEXT REFERENCES course_topics(id) ON DELETE SET NULL,
                lesson_id TEXT REFERENCES lessons(id) ON DELETE SET NULL,
                filename TEXT NOT NULL,
                file_type TEXT NOT NULL,
                extracted_text TEXT,
                word_count INTEGER,
                processing_status TEXT NOT NULL DEFAULT 'uploaded',
                processing_error TEXT,
                processed_at REAL,
                imported_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_course_materials_course_id ON course_materials(course_id)",
            """
            CREATE TABLE IF NOT EXISTS content_chunks (
                id TEXT PRIMARY KEY,
                material_id TEXT,
                course_id TEXT,
                source_filename TEXT NOT NULL,
                source_page INTEGER,
                section_heading TEXT,
                content TEXT NOT NULL,
                word_count INTEGER NOT NULL DEFAULT 0,
                concept_keys TEXT,
                created_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_content_chunks_course ON content_chunks(course_id)",
            "CREATE INDEX IF NOT EXISTS idx_content_chunks_material ON content_chunks(material_id)"
        ]

        for sql in statements {
            try execute(sql)
        }

        // Add course_id columns to existing tables (safe to retry - columns already exist)
        let alterStatements = [
            "ALTER TABLE decks ADD COLUMN course_id TEXT REFERENCES courses(id) ON DELETE SET NULL",
            "ALTER TABLE exams ADD COLUMN course_id TEXT REFERENCES courses(id) ON DELETE SET NULL",
            "ALTER TABLE study_guides ADD COLUMN course_id TEXT REFERENCES courses(id) ON DELETE SET NULL",
            "ALTER TABLE decks ADD COLUMN origin_lesson_id TEXT",
            "ALTER TABLE exams ADD COLUMN origin_lesson_id TEXT",
            "ALTER TABLE study_guides ADD COLUMN origin_lesson_id TEXT",
            "ALTER TABLE cards ADD COLUMN source_ref TEXT",
            "ALTER TABLE course_materials ADD COLUMN lesson_id TEXT REFERENCES lessons(id) ON DELETE SET NULL",
            "ALTER TABLE course_materials ADD COLUMN processing_status TEXT NOT NULL DEFAULT 'uploaded'",
            "ALTER TABLE course_materials ADD COLUMN processing_error TEXT",
            "ALTER TABLE course_materials ADD COLUMN processed_at REAL",
            "ALTER TABLE study_events ADD COLUMN adaptive_success_rate REAL",
            "ALTER TABLE study_events ADD COLUMN adaptive_target_p_success REAL",
            "ALTER TABLE study_events ADD COLUMN adaptive_chosen_p_success REAL",
            "ALTER TABLE study_events ADD COLUMN xp_amount INTEGER",
            "ALTER TABLE study_events ADD COLUMN xp_reason TEXT",
            "ALTER TABLE study_events ADD COLUMN streak_at_award INTEGER",
            "ALTER TABLE study_events ADD COLUMN celebration_type TEXT",
            "ALTER TABLE study_events ADD COLUMN threshold INTEGER",
            "ALTER TABLE study_events ADD COLUMN intensity TEXT",
            "ALTER TABLE study_events ADD COLUMN nudge_type TEXT",
            "ALTER TABLE study_events ADD COLUMN nudge_score REAL",
            "ALTER TABLE study_events ADD COLUMN source TEXT",
            "ALTER TABLE study_events ADD COLUMN cooldown_remaining_sec INTEGER",
            "ALTER TABLE study_events ADD COLUMN nudge_action_value TEXT",
            "ALTER TABLE study_events ADD COLUMN hint_level INTEGER",
            "ALTER TABLE study_events ADD COLUMN entry_point TEXT",
            "ALTER TABLE study_events ADD COLUMN challenge_mode_action_value TEXT",
            "ALTER TABLE study_events ADD COLUMN predicted_recall_bucket TEXT",
            "ALTER TABLE study_events ADD COLUMN badge_id TEXT",
            "ALTER TABLE study_events ADD COLUMN badge_tier TEXT",
            "ALTER TABLE study_events ADD COLUMN progress_before REAL",
            "ALTER TABLE study_events ADD COLUMN progress_after REAL",
            "ALTER TABLE study_events ADD COLUMN concept_count INTEGER",
            "ALTER TABLE study_events ADD COLUMN was_successful INTEGER"
        ]
        for sql in alterStatements {
            // Ignore "duplicate column name" errors
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        let postAlterStatements = [
            "CREATE INDEX IF NOT EXISTS idx_decks_origin_lesson_id ON decks(origin_lesson_id)",
            "CREATE INDEX IF NOT EXISTS idx_exams_origin_lesson_id ON exams(origin_lesson_id)",
            "CREATE INDEX IF NOT EXISTS idx_study_guides_origin_lesson_id ON study_guides(origin_lesson_id)",
            "CREATE INDEX IF NOT EXISTS idx_course_materials_lesson_id ON course_materials(lesson_id)"
        ]
        for sql in postAlterStatements {
            try execute(sql)
        }

        try migrateFTSToExternalContent()

        try backfillLessonsFromLegacyData()
    }

    /// Migrate standalone FTS5 tables (with triggers) to external content tables.
    /// The standalone FTS5 'delete' command is broken on some SQLite builds (3.51.0),
    /// causing "SQL logic error" on card UPSERTs. External content tables avoid this
    /// by reading directly from the source table.
    private func migrateFTSToExternalContent() throws {
        // Check if old triggers exist — if so, we need to migrate
        let triggerCheckSQL = "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='trg_cards_au'"
        var stmt: OpaquePointer?
        try prepare(triggerCheckSQL, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return }
        let triggerCount = sqlite3_column_int(stmt, 0)
        guard triggerCount > 0 else { return }

        // Drop old triggers
        try execute("DROP TRIGGER IF EXISTS trg_cards_au")
        try execute("DROP TRIGGER IF EXISTS trg_cards_ai")
        try execute("DROP TRIGGER IF EXISTS trg_cards_ad")
        try execute("DROP TRIGGER IF EXISTS trg_study_guides_au")
        try execute("DROP TRIGGER IF EXISTS trg_study_guides_ai")
        try execute("DROP TRIGGER IF EXISTS trg_study_guides_ad")

        // Drop old standalone FTS tables
        try execute("DROP TABLE IF EXISTS cards_fts")
        try execute("DROP TABLE IF EXISTS study_guides_fts")

        // Recreate as external content tables with views providing column name mapping
        try execute("CREATE VIEW IF NOT EXISTS cards_search_source AS SELECT rowid, id AS card_id, front, back, tags_json AS tags FROM cards")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS cards_fts USING fts5(card_id UNINDEXED, front, back, tags, content='cards_search_source', content_rowid='rowid')")
        try execute("CREATE VIEW IF NOT EXISTS study_guides_search_source AS SELECT rowid, id AS guide_id, title, markdown_content, tags_json AS tags FROM study_guides")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS study_guides_fts USING fts5(guide_id UNINDEXED, title, markdown_content, tags, content='study_guides_search_source', content_rowid='rowid')")

        // Rebuild FTS indexes from source tables
        try execute("INSERT INTO cards_fts(cards_fts) VALUES('rebuild')")
        try execute("INSERT INTO study_guides_fts(study_guides_fts) VALUES('rebuild')")
    }

    private func backfillLessonsFromLegacyData() throws {
        try createLessonsForUnassignedMaterials()
        try createSyntheticLegacyLessons()
        try normalizeMaterialProcessingState()
    }

    private func createLessonsForUnassignedMaterials() throws {
        let selectSQL = """
        SELECT id, course_id, filename, imported_at
        FROM course_materials
        WHERE lesson_id IS NULL OR lesson_id = ''
        ORDER BY imported_at ASC
        """
        var selectStatement: OpaquePointer?
        try prepare(selectSQL, into: &selectStatement)
        defer { sqlite3_finalize(selectStatement) }

        let insertLessonSQL = """
        INSERT INTO lessons (id, course_id, title, summary, created_at, updated_at, source_type, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """
        var insertLessonStatement: OpaquePointer?
        try prepare(insertLessonSQL, into: &insertLessonStatement)
        defer { sqlite3_finalize(insertLessonStatement) }

        let updateMaterialSQL = """
        UPDATE course_materials
        SET lesson_id = ?, processing_status = COALESCE(NULLIF(processing_status, ''), 'ready'), processed_at = COALESCE(processed_at, imported_at)
        WHERE id = ?
        """
        var updateMaterialStatement: OpaquePointer?
        try prepare(updateMaterialSQL, into: &updateMaterialStatement)
        defer { sqlite3_finalize(updateMaterialStatement) }

        while sqlite3_step(selectStatement) == SQLITE_ROW {
            guard let materialIdString = columnString(selectStatement, at: 0), let materialId = UUID(uuidString: materialIdString) else { continue }
            guard let courseIdString = columnString(selectStatement, at: 1), let courseId = UUID(uuidString: courseIdString) else { continue }
            let filename = columnString(selectStatement, at: 2) ?? "Imported Material"
            let importedAt = Date(timeIntervalSince1970: columnDouble(selectStatement, at: 3))

            let lesson = LessonDTO(
                id: UUID(),
                courseId: courseId,
                title: makeLessonTitle(fromFilename: filename),
                summary: "Auto-created from uploaded material.",
                createdAt: importedAt,
                updatedAt: importedAt,
                sourceType: .upload,
                status: .ready
            )

            sqlite3_reset(insertLessonStatement)
            sqlite3_clear_bindings(insertLessonStatement)
            try bind(lesson.id.uuidString, to: 1, in: insertLessonStatement)
            try bind(lesson.courseId.uuidString, to: 2, in: insertLessonStatement)
            try bind(lesson.title, to: 3, in: insertLessonStatement)
            try bind(lesson.summary, to: 4, in: insertLessonStatement)
            try bind(lesson.createdAt.timeIntervalSince1970, to: 5, in: insertLessonStatement)
            try bind(lesson.updatedAt.timeIntervalSince1970, to: 6, in: insertLessonStatement)
            try bind(lesson.sourceType.rawValue, to: 7, in: insertLessonStatement)
            try bind(lesson.status.rawValue, to: 8, in: insertLessonStatement)
            try stepDone(insertLessonStatement)

            sqlite3_reset(updateMaterialStatement)
            sqlite3_clear_bindings(updateMaterialStatement)
            try bind(lesson.id.uuidString, to: 1, in: updateMaterialStatement)
            try bind(materialId.uuidString, to: 2, in: updateMaterialStatement)
            try stepDone(updateMaterialStatement)
        }
    }

    private func createSyntheticLegacyLessons() throws {
        let selectCoursesSQL = """
        SELECT c.id, c.name
        FROM courses c
        WHERE NOT EXISTS (SELECT 1 FROM lessons l WHERE l.course_id = c.id)
          AND (
            EXISTS (SELECT 1 FROM course_topics t WHERE t.course_id = c.id)
            OR EXISTS (SELECT 1 FROM decks d WHERE d.course_id = c.id)
            OR EXISTS (SELECT 1 FROM exams e WHERE e.course_id = c.id)
            OR EXISTS (SELECT 1 FROM study_guides g WHERE g.course_id = c.id)
          )
        """
        var selectCoursesStatement: OpaquePointer?
        try prepare(selectCoursesSQL, into: &selectCoursesStatement)
        defer { sqlite3_finalize(selectCoursesStatement) }

        let selectTopicsSQL = """
        SELECT id, name
        FROM course_topics
        WHERE course_id = ?
        ORDER BY sort_order ASC
        """
        var selectTopicsStatement: OpaquePointer?
        try prepare(selectTopicsSQL, into: &selectTopicsStatement)
        defer { sqlite3_finalize(selectTopicsStatement) }

        let insertLessonSQL = """
        INSERT INTO lessons (id, course_id, title, summary, created_at, updated_at, source_type, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO NOTHING
        """
        var insertLessonStatement: OpaquePointer?
        try prepare(insertLessonSQL, into: &insertLessonStatement)
        defer { sqlite3_finalize(insertLessonStatement) }

        let assignDecksSQL = "UPDATE decks SET origin_lesson_id = ? WHERE course_id = ? AND origin_lesson_id IS NULL"
        let assignExamsSQL = "UPDATE exams SET origin_lesson_id = ? WHERE course_id = ? AND origin_lesson_id IS NULL"
        let assignGuidesSQL = "UPDATE study_guides SET origin_lesson_id = ? WHERE course_id = ? AND origin_lesson_id IS NULL"

        var assignDecksStatement: OpaquePointer?
        var assignExamsStatement: OpaquePointer?
        var assignGuidesStatement: OpaquePointer?
        try prepare(assignDecksSQL, into: &assignDecksStatement)
        try prepare(assignExamsSQL, into: &assignExamsStatement)
        try prepare(assignGuidesSQL, into: &assignGuidesStatement)
        defer {
            sqlite3_finalize(assignDecksStatement)
            sqlite3_finalize(assignExamsStatement)
            sqlite3_finalize(assignGuidesStatement)
        }

        while sqlite3_step(selectCoursesStatement) == SQLITE_ROW {
            guard let courseIdString = columnString(selectCoursesStatement, at: 0), let courseId = UUID(uuidString: courseIdString) else { continue }
            let courseName = columnString(selectCoursesStatement, at: 1) ?? "Legacy Course"

            var topicNames: [String] = []
            sqlite3_reset(selectTopicsStatement)
            sqlite3_clear_bindings(selectTopicsStatement)
            try bind(courseId.uuidString, to: 1, in: selectTopicsStatement)
            while sqlite3_step(selectTopicsStatement) == SQLITE_ROW {
                let topicName = (columnString(selectTopicsStatement, at: 1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !topicName.isEmpty {
                    topicNames.append(topicName)
                }
            }

            let now = Date()
            let lessonTitles: [String]
            if topicNames.isEmpty {
                lessonTitles = ["Legacy Lesson"]
            } else {
                lessonTitles = topicNames
            }

            var firstLessonId: UUID?
            for lessonTitle in lessonTitles {
                let lessonId = UUID()
                if firstLessonId == nil { firstLessonId = lessonId }
                sqlite3_reset(insertLessonStatement)
                sqlite3_clear_bindings(insertLessonStatement)
                try bind(lessonId.uuidString, to: 1, in: insertLessonStatement)
                try bind(courseId.uuidString, to: 2, in: insertLessonStatement)
                try bind(lessonTitle, to: 3, in: insertLessonStatement)
                try bind("Migrated from legacy course data (\(courseName)).", to: 4, in: insertLessonStatement)
                try bind(now.timeIntervalSince1970, to: 5, in: insertLessonStatement)
                try bind(now.timeIntervalSince1970, to: 6, in: insertLessonStatement)
                try bind(LessonSourceType.legacy.rawValue, to: 7, in: insertLessonStatement)
                try bind(LessonStatus.ready.rawValue, to: 8, in: insertLessonStatement)
                try stepDone(insertLessonStatement)
            }

            guard let legacyLessonId = firstLessonId else { continue }

            sqlite3_reset(assignDecksStatement)
            sqlite3_clear_bindings(assignDecksStatement)
            try bind(legacyLessonId.uuidString, to: 1, in: assignDecksStatement)
            try bind(courseId.uuidString, to: 2, in: assignDecksStatement)
            try stepDone(assignDecksStatement)

            sqlite3_reset(assignExamsStatement)
            sqlite3_clear_bindings(assignExamsStatement)
            try bind(legacyLessonId.uuidString, to: 1, in: assignExamsStatement)
            try bind(courseId.uuidString, to: 2, in: assignExamsStatement)
            try stepDone(assignExamsStatement)

            sqlite3_reset(assignGuidesStatement)
            sqlite3_clear_bindings(assignGuidesStatement)
            try bind(legacyLessonId.uuidString, to: 1, in: assignGuidesStatement)
            try bind(courseId.uuidString, to: 2, in: assignGuidesStatement)
            try stepDone(assignGuidesStatement)
        }
    }

    private func normalizeMaterialProcessingState() throws {
        let sql = """
        UPDATE course_materials
        SET processing_status = COALESCE(NULLIF(processing_status, ''), 'ready'),
            processed_at = COALESCE(processed_at, imported_at)
        """
        try execute(sql)
    }

    private func makeLessonTitle(fromFilename filename: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let cleaned = base.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Lesson" : cleaned
    }

    private func deleteExamQuestions(examID: UUID) throws {
        let sql = "DELETE FROM exam_questions WHERE exam_id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(examID.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    private func deleteStudyGuideAttachments(studyGuideID: UUID) throws {
        let sql = "DELETE FROM study_guide_attachments WHERE study_guide_id = ?"
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(studyGuideID.uuidString, to: 1, in: statement)
        try stepDone(statement)
    }

    private func fetchExams(sql: String, bindings: [SQLiteBinding]) throws -> [ExamDTO] {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, in: statement)

        var exams: [ExamDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = columnString(statement, at: 0), let id = UUID(uuidString: idString) else { continue }
            let parentFolderID = columnString(statement, at: 1).flatMap(UUID.init(uuidString:))
            let title = columnString(statement, at: 2) ?? "Exam"
            let timeLimit = columnOptionalInt(statement, at: 3)
            let shuffle = columnInt(statement, at: 4) != 0
            let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 5))
            let updatedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 6))
            let courseId = columnString(statement, at: 7).flatMap(UUID.init(uuidString:))
            let originLessonId = columnString(statement, at: 8).flatMap(UUID.init(uuidString:))
            let questions = try fetchExamQuestions(examID: id)

            exams.append(
                ExamDTO(
                    id: id,
                    parentFolderId: parentFolderID,
                    courseId: courseId,
                    originLessonId: originLessonId,
                    title: title,
                    config: ExamDTO.ConfigDTO(timeLimit: timeLimit, shuffleQuestions: shuffle),
                    questions: questions,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }

        return exams
    }

    private func fetchExamQuestions(examID: UUID) throws -> [ExamDTO.QuestionDTO] {
        let sql = """
        SELECT id, prompt, choices_json, correct_choice_index
        FROM exam_questions
        WHERE exam_id = ?
        ORDER BY sort_order ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(examID.uuidString, to: 1, in: statement)

        var questions: [ExamDTO.QuestionDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = columnString(statement, at: 0), let id = UUID(uuidString: idString) else { continue }
            let prompt = columnString(statement, at: 1) ?? ""
            let choices = decodeJSONString(columnString(statement, at: 2), as: [String].self) ?? []
            let correctIndex = Int(columnInt(statement, at: 3))
            questions.append(
                ExamDTO.QuestionDTO(
                    id: id,
                    prompt: prompt,
                    choices: choices,
                    correctChoiceIndex: correctIndex
                )
            )
        }

        return questions
    }

    private func fetchStudyGuides(sql: String, bindings: [SQLiteBinding]) throws -> [StudyGuideDTO] {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, in: statement)

        var guides: [StudyGuideDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = columnString(statement, at: 0), let id = UUID(uuidString: idString) else { continue }
            let parentFolderID = columnString(statement, at: 1).flatMap(UUID.init(uuidString:))
            let title = columnString(statement, at: 2) ?? "Study Guide"
            let markdown = columnString(statement, at: 3) ?? ""
            let tags = decodeJSONString(columnString(statement, at: 4), as: [String].self) ?? []
            let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 5))
            let lastEditedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 6))
            let courseId = columnString(statement, at: 7).flatMap(UUID.init(uuidString:))
            let originLessonId = columnString(statement, at: 8).flatMap(UUID.init(uuidString:))
            let attachments = try fetchStudyGuideAttachments(studyGuideID: id)

            guides.append(
                StudyGuideDTO(
                    id: id,
                    parentFolderId: parentFolderID,
                    courseId: courseId,
                    originLessonId: originLessonId,
                    title: title,
                    markdownContent: markdown,
                    attachments: attachments,
                    tags: tags,
                    createdAt: createdAt,
                    lastEditedAt: lastEditedAt
                )
            )
        }

        return guides
    }

    private func fetchStudyGuideAttachments(studyGuideID: UUID) throws -> [StudyGuideAttachmentDTO] {
        let sql = """
        SELECT id, filename, relative_path, mime_type, size_bytes, created_at
        FROM study_guide_attachments
        WHERE study_guide_id = ?
        ORDER BY sort_order ASC
        """
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(studyGuideID.uuidString, to: 1, in: statement)

        var attachments: [StudyGuideAttachmentDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = columnString(statement, at: 0), let id = UUID(uuidString: idString) else { continue }
            attachments.append(
                StudyGuideAttachmentDTO(
                    id: id,
                    filename: columnString(statement, at: 1) ?? "",
                    relativePath: columnString(statement, at: 2) ?? "",
                    mimeType: columnString(statement, at: 3) ?? "application/octet-stream",
                    sizeBytes: Int64(columnInt64(statement, at: 4)),
                    createdAt: Date(timeIntervalSince1970: columnDouble(statement, at: 5))
                )
            )
        }

        return attachments
    }

    private func cardSelectSQL(joinClause: String = "", whereClause: String?, orderBy: String) -> String {
        let whereSQL = whereClause.map { "WHERE \($0)" } ?? ""
        return """
        SELECT
            c.id, c.deck_id, c.kind, c.front, c.back, c.cloze_source, c.choices_json,
            c.correct_choice_index, c.tags_json, c.media_json, c.created_at, c.updated_at,
            c.is_suspended, c.suspended_by_archive, c.source_ref,
            s.id, s.ease_factor, s.interval_days, s.repetitions, s.lapses, s.due_date,
            s.last_reviewed, s.queue, s.stability, s.difficulty, s.fsrs_reps, s.last_elapsed_seconds
        FROM cards c
        LEFT JOIN srs_states s ON s.card_id = c.id
        \(joinClause)
        \(whereSQL)
        \(orderBy)
        """
    }

    private func fetchCards(sql: String, bindings: [SQLiteBinding]) throws -> [CardDTO] {
        var statement: OpaquePointer?
        try prepare(sql, into: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, in: statement)

        var cards: [CardDTO] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            cards.append(try decodeCard(statement))
        }
        return cards
    }

    private func decodeDeck(_ statement: OpaquePointer?) throws -> DeckDTO {
        guard let idValue = columnString(statement, at: 0), let id = UUID(uuidString: idValue) else {
            throw StorageError.decodingFailed("Invalid deck id")
        }
        let parent = columnString(statement, at: 1).flatMap(UUID.init(uuidString:))
        let kindRaw = columnString(statement, at: 2) ?? Deck.Kind.deck.rawValue
        let kind = Deck.Kind(rawValue: kindRaw) ?? .deck
        let name = columnString(statement, at: 3) ?? ""
        let note = columnString(statement, at: 4)
        let dueDate = columnOptionalDouble(statement, at: 5).map(Date.init(timeIntervalSince1970:))
        let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 6))
        let updatedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 7))
        let archived = columnInt(statement, at: 8) != 0
        let courseId = columnString(statement, at: 9).flatMap(UUID.init(uuidString:))
        let originLessonId = columnString(statement, at: 10).flatMap(UUID.init(uuidString:))

        return DeckDTO(
            id: id,
            parentId: parent,
            courseId: courseId,
            originLessonId: originLessonId,
            kind: kind,
            name: name,
            note: note,
            dueDate: dueDate,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isArchived: archived
        )
    }

    private func decodeCard(_ statement: OpaquePointer?) throws -> CardDTO {
        guard let idValue = columnString(statement, at: 0), let id = UUID(uuidString: idValue) else {
            throw StorageError.decodingFailed("Invalid card id")
        }

        let deckID = columnString(statement, at: 1).flatMap(UUID.init(uuidString:))
        let kindRaw = columnString(statement, at: 2) ?? CardDTO.Kind.basic.rawValue
        let kind = CardDTO.Kind(rawValue: kindRaw) ?? .basic
        let front = columnString(statement, at: 3) ?? ""
        let back = columnString(statement, at: 4) ?? ""
        let clozeSource = columnString(statement, at: 5)
        let choices = decodeJSONString(columnString(statement, at: 6), as: [String].self) ?? []
        let correctChoiceIndex = columnOptionalInt(statement, at: 7)
        let tags = decodeJSONString(columnString(statement, at: 8), as: [String].self) ?? []
        let media = decodeJSONString(columnString(statement, at: 9), as: [URL].self) ?? []
        let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 10))
        let updatedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 11))
        let isSuspended = columnInt(statement, at: 12) != 0
        let suspendedByArchive = columnInt(statement, at: 13) != 0
        let sourceRef = columnString(statement, at: 14)

        let srsIDString = columnString(statement, at: 15)
        let srsID = srsIDString.flatMap(UUID.init(uuidString:)) ?? UUID()
        let queueRaw = columnString(statement, at: 22) ?? SRSStateDTO.Queue.new.rawValue
        let queue = SRSStateDTO.Queue(rawValue: queueRaw) ?? .new

        let srs = SRSStateDTO(
            id: srsID,
            cardId: id,
            easeFactor: columnOptionalDouble(statement, at: 16) ?? 2.5,
            interval: Int(columnOptionalInt(statement, at: 17) ?? 0),
            repetitions: Int(columnOptionalInt(statement, at: 18) ?? 0),
            lapses: Int(columnOptionalInt(statement, at: 19) ?? 0),
            dueDate: Date(timeIntervalSince1970: columnOptionalDouble(statement, at: 20) ?? createdAt.timeIntervalSince1970),
            lastReviewed: columnOptionalDouble(statement, at: 21).map(Date.init(timeIntervalSince1970:)),
            queue: queue,
            stability: columnOptionalDouble(statement, at: 23) ?? 0.6,
            difficulty: columnOptionalDouble(statement, at: 24) ?? 5.0,
            fsrsReps: Int(columnOptionalInt(statement, at: 25) ?? 0),
            lastElapsedSeconds: columnOptionalDouble(statement, at: 26)
        )

        return CardDTO(
            id: id,
            deckId: deckID,
            kind: kind,
            front: front,
            back: back,
            clozeSource: clozeSource,
            choices: choices,
            correctChoiceIndex: correctChoiceIndex,
            tags: tags,
            sourceRef: sourceRef,
            media: media,
            createdAt: createdAt,
            updatedAt: updatedAt,
            isSuspended: isSuspended,
            suspendedByArchive: suspendedByArchive,
            srs: srs
        )
    }

    private func decodeReviewLog(_ statement: OpaquePointer?) throws -> ReviewLogDTO {
        guard
            let idString = columnString(statement, at: 0),
            let id = UUID(uuidString: idString),
            let cardIDString = columnString(statement, at: 1),
            let cardID = UUID(uuidString: cardIDString)
        else {
            throw StorageError.decodingFailed("Invalid review log row")
        }

        return ReviewLogDTO(
            id: id,
            cardId: cardID,
            timestamp: Date(timeIntervalSince1970: columnDouble(statement, at: 2)),
            grade: Int(columnInt(statement, at: 3)),
            elapsedMs: Int(columnInt(statement, at: 4)),
            prevInterval: Int(columnInt(statement, at: 5)),
            nextInterval: Int(columnInt(statement, at: 6)),
            prevEase: columnDouble(statement, at: 7),
            nextEase: columnDouble(statement, at: 8),
            prevStability: columnDouble(statement, at: 9),
            nextStability: columnDouble(statement, at: 10),
            prevDifficulty: columnDouble(statement, at: 11),
            nextDifficulty: columnDouble(statement, at: 12),
            predictedRecall: columnDouble(statement, at: 13),
            requestedRetention: columnDouble(statement, at: 14)
        )
    }

    private func decodeStudyEvent(_ statement: OpaquePointer?) throws -> StudyEventDTO {
        guard
            let idString = columnString(statement, at: 0),
            let id = UUID(uuidString: idString),
            let sessionIDString = columnString(statement, at: 2),
            let sessionID = UUID(uuidString: sessionIDString),
            let kindRaw = columnString(statement, at: 3),
            let kind = StudyEventDTO.Kind(rawValue: kindRaw)
        else {
            throw StorageError.decodingFailed("Invalid study event row")
        }

        return StudyEventDTO(
            id: id,
            timestamp: Date(timeIntervalSince1970: columnDouble(statement, at: 1)),
            sessionId: sessionID,
            kind: kind,
            deckId: columnString(statement, at: 4).flatMap(UUID.init(uuidString:)),
            cardId: columnString(statement, at: 5).flatMap(UUID.init(uuidString:)),
            queueMode: columnString(statement, at: 6),
            attemptIndex: columnOptionalInt(statement, at: 7),
            conceptsAtTime: decodeJSONString(columnString(statement, at: 8), as: [String].self),
            elapsedMs: columnOptionalInt(statement, at: 9),
            grade: columnOptionalInt(statement, at: 10),
            predictedRecallAtStart: columnOptionalDouble(statement, at: 11),
            confusionScore: columnOptionalDouble(statement, at: 12),
            confusionReasons: decodeJSONString(columnString(statement, at: 13), as: [String].self),
            interventionKind: columnString(statement, at: 14),
            interventionAction: columnString(statement, at: 15),
            adaptiveSuccessRate: columnOptionalDouble(statement, at: 16),
            adaptiveTargetPSuccess: columnOptionalDouble(statement, at: 17),
            adaptiveChosenPSuccess: columnOptionalDouble(statement, at: 18),
            xpAmount: columnOptionalInt(statement, at: 19),
            xpReason: columnString(statement, at: 20),
            streakAtAward: columnOptionalInt(statement, at: 21),
            celebrationType: columnString(statement, at: 22),
            threshold: columnOptionalInt(statement, at: 23),
            intensity: columnString(statement, at: 24),
            nudgeType: columnString(statement, at: 25),
            nudgeScore: columnOptionalDouble(statement, at: 26),
            source: columnString(statement, at: 27),
            cooldownRemainingSec: columnOptionalInt(statement, at: 28),
            nudgeActionValue: columnString(statement, at: 29),
            hintLevel: columnOptionalInt(statement, at: 30),
            entryPoint: columnString(statement, at: 31),
            challengeModeActionValue: columnString(statement, at: 32),
            predictedRecallBucket: columnString(statement, at: 33),
            badgeId: columnString(statement, at: 34),
            badgeTier: columnString(statement, at: 35),
            progressBefore: columnOptionalDouble(statement, at: 36),
            progressAfter: columnOptionalDouble(statement, at: 37),
            conceptCount: columnOptionalInt(statement, at: 38),
            wasSuccessful: columnOptionalInt(statement, at: 39).map { $0 != 0 }
        )
    }

    private func decodeCourse(_ statement: OpaquePointer?) throws -> CourseDTO {
        guard let idValue = columnString(statement, at: 0), let id = UUID(uuidString: idValue) else {
            throw StorageError.decodingFailed("Invalid course id")
        }
        let name = columnString(statement, at: 1) ?? ""
        let courseCode = columnString(statement, at: 2)
        let examDate = columnOptionalDouble(statement, at: 3).map(Date.init(timeIntervalSince1970:))
        let weeklyTimeBudgetMinutes = columnOptionalInt(statement, at: 4)
        let colorHex = columnString(statement, at: 5)
        let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 6))
        let updatedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 7))

        return CourseDTO(
            id: id,
            name: name,
            courseCode: courseCode,
            examDate: examDate,
            weeklyTimeBudgetMinutes: weeklyTimeBudgetMinutes,
            colorHex: colorHex,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func decodeLesson(_ statement: OpaquePointer?) throws -> LessonDTO {
        guard let idValue = columnString(statement, at: 0), let id = UUID(uuidString: idValue) else {
            throw StorageError.decodingFailed("Invalid lesson id")
        }
        guard let courseIdValue = columnString(statement, at: 1), let courseId = UUID(uuidString: courseIdValue) else {
            throw StorageError.decodingFailed("Invalid lesson course_id")
        }

        let title = columnString(statement, at: 2) ?? "Lesson"
        let summary = columnString(statement, at: 3)
        let createdAt = Date(timeIntervalSince1970: columnDouble(statement, at: 4))
        let updatedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 5))
        let sourceTypeRaw = columnString(statement, at: 6) ?? LessonSourceType.upload.rawValue
        let statusRaw = columnString(statement, at: 7) ?? LessonStatus.ready.rawValue

        return LessonDTO(
            id: id,
            courseId: courseId,
            title: title,
            summary: summary,
            createdAt: createdAt,
            updatedAt: updatedAt,
            sourceType: LessonSourceType(rawValue: sourceTypeRaw) ?? .upload,
            status: LessonStatus(rawValue: statusRaw) ?? .ready
        )
    }

    private func decodeTopic(_ statement: OpaquePointer?) throws -> CourseTopicDTO {
        guard let idValue = columnString(statement, at: 0), let id = UUID(uuidString: idValue) else {
            throw StorageError.decodingFailed("Invalid topic id")
        }
        guard let courseIdValue = columnString(statement, at: 1), let courseId = UUID(uuidString: courseIdValue) else {
            throw StorageError.decodingFailed("Invalid topic course_id")
        }
        let name = columnString(statement, at: 2) ?? ""
        let sortOrder = Int(columnInt(statement, at: 3))
        let sourceDescription = columnString(statement, at: 4)

        return CourseTopicDTO(
            id: id,
            courseId: courseId,
            name: name,
            sortOrder: sortOrder,
            sourceDescription: sourceDescription
        )
    }

    private func decodeMaterial(_ statement: OpaquePointer?) throws -> CourseMaterialDTO {
        guard let idValue = columnString(statement, at: 0), let id = UUID(uuidString: idValue) else {
            throw StorageError.decodingFailed("Invalid material id")
        }
        guard let courseIdValue = columnString(statement, at: 1), let courseId = UUID(uuidString: courseIdValue) else {
            throw StorageError.decodingFailed("Invalid material course_id")
        }
        let topicId = columnString(statement, at: 2).flatMap(UUID.init(uuidString:))
        let lessonId = columnString(statement, at: 3).flatMap(UUID.init(uuidString:))
        let filename = columnString(statement, at: 4) ?? ""
        let fileType = columnString(statement, at: 5) ?? ""
        let extractedText = columnString(statement, at: 6)
        let wordCount = columnOptionalInt(statement, at: 7)
        let processingStatusRaw = columnString(statement, at: 8) ?? CourseMaterialProcessingStatus.ready.rawValue
        let processingStatus = CourseMaterialProcessingStatus(rawValue: processingStatusRaw) ?? .ready
        let processingError = columnString(statement, at: 9)
        let processedAt = columnOptionalDouble(statement, at: 10).map(Date.init(timeIntervalSince1970:))
        let importedAt = Date(timeIntervalSince1970: columnDouble(statement, at: 11))

        return CourseMaterialDTO(
            id: id,
            courseId: courseId,
            topicId: topicId,
            lessonId: lessonId,
            filename: filename,
            fileType: fileType,
            extractedText: extractedText,
            wordCount: wordCount,
            processingStatus: processingStatus,
            processingError: processingError,
            processedAt: processedAt,
            importedAt: importedAt
        )
    }

    private func filterArchived(_ cards: [CardDTO]) throws -> [CardDTO] {
        let decks = try allDecks()
        let deckByID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        return cards.filter { card in
            guard let deckID = card.deckId else { return true }
            return !isDeckArchivedIncludingAncestors(deckID: deckID, deckByID: deckByID)
        }
    }

    private func isDeckArchivedIncludingAncestors(deckID: UUID, deckByID: [UUID: DeckDTO]) -> Bool {
        var current: UUID? = deckID
        var seen: Set<UUID> = []
        while let id = current, let deck = deckByID[id] {
            if deck.isArchived { return true }
            if !seen.insert(id).inserted { return false }
            current = deck.parentId
        }
        return false
    }

    private func buildFTSQuery(from text: String) -> String {
        let terms = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return "\"\(text.replacingOccurrences(of: "\"", with: ""))\""
        }
        return terms.map { "\"\($0)\"" }.joined(separator: " AND ")
    }

    private func execute(_ sql: String) throws {
        guard let db else {
            throw StorageError.initializationFailed("SQLite handle unavailable")
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(errorPointer)
            throw StorageError.initializationFailed("SQLite exec failed: \(message)")
        }
    }

    private func prepare(_ sql: String, into statement: inout OpaquePointer?) throws {
        guard let db else {
            throw StorageError.initializationFailed("SQLite handle unavailable")
        }
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw StorageError.initializationFailed("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard let db else {
            throw StorageError.initializationFailed("SQLite handle unavailable")
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw StorageError.initializationFailed("SQLite step failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func bind(_ bindings: [SQLiteBinding], in statement: OpaquePointer?) throws {
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let value):
                try bind(value, to: position, in: statement)
            case .int64(let value):
                try bind(value, to: position, in: statement)
            case .double(let value):
                try bind(value, to: position, in: statement)
            case .text(let value):
                try bind(value, to: position, in: statement)
            case .blob(let value):
                try bind(value, to: position, in: statement)
            case .null:
                try bindNil(to: position, in: statement)
            }
        }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) throws {
        if let value {
            guard sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor) == SQLITE_OK else {
                throw StorageError.initializationFailed("Failed to bind text value")
            }
        } else {
            try bindNil(to: index, in: statement)
        }
    }

    private func bind(_ value: Data?, to index: Int32, in statement: OpaquePointer?) throws {
        guard let value else {
            try bindNil(to: index, in: statement)
            return
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransientDestructor)
        }
        guard result == SQLITE_OK else {
            throw StorageError.initializationFailed("Failed to bind blob value")
        }
    }

    private func bind(_ value: Int?, to index: Int32, in statement: OpaquePointer?) throws {
        if let value {
            guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
                throw StorageError.initializationFailed("Failed to bind int value")
            }
        } else {
            try bindNil(to: index, in: statement)
        }
    }

    private func bind(_ value: Int, to index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_int(statement, index, Int32(value)) == SQLITE_OK else {
            throw StorageError.initializationFailed("Failed to bind int value")
        }
    }

    private func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer?) throws {
        if let value {
            guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
                throw StorageError.initializationFailed("Failed to bind int64 value")
            }
        } else {
            try bindNil(to: index, in: statement)
        }
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_int64(statement, index, sqlite3_int64(value)) == SQLITE_OK else {
            throw StorageError.initializationFailed("Failed to bind int64 value")
        }
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer?) throws {
        if let value {
            guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
                throw StorageError.initializationFailed("Failed to bind double value")
            }
        } else {
            try bindNil(to: index, in: statement)
        }
    }

    private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw StorageError.initializationFailed("Failed to bind double value")
        }
    }

    private func bindNil(to index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
            throw StorageError.initializationFailed("Failed to bind null value")
        }
    }

    private func columnString(_ statement: OpaquePointer?, at index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let cValue = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: cValue)
    }

    private func columnInt(_ statement: OpaquePointer?, at index: Int32) -> Int32 {
        sqlite3_column_int(statement, index)
    }

    private func columnOptionalInt(_ statement: OpaquePointer?, at index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func columnInt64(_ statement: OpaquePointer?, at index: Int32) -> Int64 {
        Int64(sqlite3_column_int64(statement, index))
    }

    private func columnOptionalInt64(_ statement: OpaquePointer?, at index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int64(sqlite3_column_int64(statement, index))
    }

    private func columnDouble(_ statement: OpaquePointer?, at index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    private func columnOptionalDouble(_ statement: OpaquePointer?, at index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private func columnData(_ statement: OpaquePointer?, at index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        let length = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: length)
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw StorageError.encodingFailed("Failed to encode JSON string")
        }
        return encoded
    }

    private func optionalJsonString<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        let data = try encoder.encode(value)
        guard let encoded = String(data: data, encoding: .utf8) else {
            throw StorageError.encodingFailed("Failed to encode JSON string")
        }
        return encoded
    }

    private func decodeJSONString<T: Decodable>(_ string: String?, as type: T.Type) -> T? {
        guard let string, let data = string.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func clearDirectory(_ directory: URL) throws {
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let items = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in items {
            try fileManager.removeItem(at: item)
        }
    }

    private func migrateLegacyStudyGuidesIfNeeded() throws {
        let legacyURL = paths.root.appendingPathComponent("study_guides.json", isDirectory: false)
        guard fileManager.fileExists(atPath: legacyURL.path) else { return }
        guard try allStudyGuides().isEmpty else { return }

        let data = try Data(contentsOf: legacyURL)
        guard !data.isEmpty else { return }

        let guides = try decoder.decode([StudyGuideDTO].self, from: data)
        for guide in guides {
            try upsert(studyGuide: guide)
        }
    }

    private static func resolveRootURL(_ input: URL?) throws -> URL {
        if let input {
            return input
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StorageError.initializationFailed("Unable to locate Application Support directory")
        }
        return base.appendingPathComponent("revu", isDirectory: true).appendingPathComponent("v1", isDirectory: true)
    }

    private static func makePaths(root: URL) throws -> Paths {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let attachments = root.appendingPathComponent("attachments", isDirectory: true)
        if !fileManager.fileExists(atPath: attachments.path) {
            try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        }

        let backups = root.appendingPathComponent("backups", isDirectory: true)
        if !fileManager.fileExists(atPath: backups.path) {
            try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        }

        return Paths(
            root: root,
            database: root.appendingPathComponent("revu.sqlite3", isDirectory: false),
            attachments: attachments,
            backups: backups
        )
    }
}

private enum SQLiteBinding {
    case int(Int)
    case int64(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}
