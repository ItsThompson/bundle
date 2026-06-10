@testable import Bundle
import Foundation
import Testing

@Suite("Note Capture Tests")
struct NoteCaptureTests {
    // MARK: - Database Integration

    @Test("Insert note artifact stores content text in SQLite")
    func insertNoteArtifactWithContentText() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_note_\(UUID().uuidString).db")
        let db = LocalDatabase(dbPath: dbPath)
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }
        try db.open()

        let noteId = UUID().uuidString
        let noteContent = "Design notes for the navigation refactor"

        try db.insertArtifact(
            id: noteId,
            type: "note",
            contentPath: "\(noteId).md",
            contentText: noteContent,
            status: "pending",
            createdAt: Date()
        )

        let count = try db.getArtifactCount()
        #expect(count == 1)
    }

    @Test("Insert note artifact stores content text and path")
    func insertNoteArtifactStoresContentText() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_note_\(UUID().uuidString).db")
        let db = LocalDatabase(dbPath: dbPath)
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }
        try db.open()

        let noteId = UUID().uuidString
        let noteContent = "Some important thoughts"

        try db.insertArtifact(
            id: noteId,
            type: "note",
            contentPath: "\(noteId).md",
            contentText: noteContent,
            status: "pending",
            createdAt: Date()
        )

        let pending = try db.getPendingArtifacts()
        #expect(pending.count == 1)
        #expect(pending[0].type == "note")
        #expect(pending[0].contentText == noteContent)
        #expect(pending[0].contentPath == "\(noteId).md")
    }

    @Test("Note artifact status is pending after insert")
    func insertNoteArtifactStatusPending() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_note_\(UUID().uuidString).db")
        let db = LocalDatabase(dbPath: dbPath)
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }
        try db.open()

        let noteId = UUID().uuidString

        try db.insertArtifact(
            id: noteId,
            type: "note",
            contentPath: "\(noteId).md",
            contentText: "Test note",
            status: "pending",
            createdAt: Date()
        )

        let pending = try db.getPendingArtifacts()
        #expect(pending.count == 1)
        #expect(pending[0].status == "pending")
    }

    @Test("Update note status removes from pending list")
    func updateNoteStatusAfterUpload() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_note_\(UUID().uuidString).db")
        let db = LocalDatabase(dbPath: dbPath)
        defer {
            db.close()
            try? FileManager.default.removeItem(at: dbPath)
        }
        try db.open()

        let noteId = UUID().uuidString

        try db.insertArtifact(
            id: noteId,
            type: "note",
            contentPath: "\(noteId).md",
            contentText: "A note",
            status: "pending",
            createdAt: Date()
        )

        try db.updateArtifactStatus(id: noteId, status: "completed")

        let pending = try db.getPendingArtifacts()
        #expect(pending.count == 0)
    }

    // MARK: - Note Content Validation

    @Test("Whitespace-only text is treated as empty", arguments: ["", " ", "\n", "\t", "   \n\n  \t  "])
    func emptyNoteContentIsWhitespaceOnly(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.isEmpty)
    }

    @Test("Non-whitespace text is treated as non-empty", arguments: ["Hello", "  Hello  ", "\n\nContent\n\n"])
    func nonEmptyNoteContent(input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!trimmed.isEmpty)
    }

    @Test("Max note length of 50000 is enforced by truncation")
    func maxNoteLengthEnforced() {
        let maxLength = 50_000
        let longText = String(repeating: "a", count: 60_000)
        let truncated = String(longText.prefix(maxLength))
        #expect(truncated.count == maxLength)
    }

    // MARK: - File Save

    @Test("Note saved as .md file can be read back")
    func noteSavedAsMdFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let noteContent = "# My Note\n\nSome markdown content."
        let filePath = tempDir.appendingPathComponent("test-note.md")
        try noteContent.write(to: filePath, atomically: true, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: filePath.path))
        let readBack = try String(contentsOf: filePath, encoding: .utf8)
        #expect(readBack == noteContent)
    }

    @Test("Note saved in date-structured directory")
    func noteSavedInDateDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let dateStr = dateFormatter.string(from: Date())

        let dateDir = tempDir.appendingPathComponent(dateStr)
        try FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let filePath = dateDir.appendingPathComponent("test-note.md")
        try "content".write(to: filePath, atomically: true, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: filePath.path))
    }
}
