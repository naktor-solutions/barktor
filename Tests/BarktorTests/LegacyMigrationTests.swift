import Foundation
import Testing

@testable import Barktor

struct LegacyMigrationTests {
    // MARK: rewriteLegacyPath

    @Test func rewritesPathsInsideTheLegacyRoot() {
        let support = "/Users/x/Library/Application Support"
        #expect(
            LegacyMigration.rewriteLegacyPath("\(support)/Purr/models", supportPath: support)
                == "\(support)/Barktor/models")
        #expect(
            LegacyMigration.rewriteLegacyPath("\(support)/Purr", supportPath: support)
                == "\(support)/Barktor")
    }

    @Test func rewritesTheLegacyDefaultMeetingsFolder() {
        let support = "/Users/x/Library/Application Support"
        #expect(
            LegacyMigration.rewriteLegacyPath(
                "\(support)/Purr/Purr Meetings", supportPath: support)
                == "\(support)/Barktor/Meetings")
        #expect(
            LegacyMigration.rewriteLegacyPath(
                "\(support)/Purr/Purr Meetings/notes", supportPath: support)
                == "\(support)/Barktor/Meetings/notes")
    }

    @Test func leavesUnrelatedPathsAlone() {
        let support = "/Users/x/Library/Application Support"
        #expect(
            LegacyMigration.rewriteLegacyPath("/Users/x/Documents/Meetings", supportPath: support)
                == "/Users/x/Documents/Meetings")
        // Sibling folder whose name merely starts with "Purr".
        #expect(
            LegacyMigration.rewriteLegacyPath("\(support)/Purrfect/x", supportPath: support)
                == "\(support)/Purrfect/x")
    }

    // MARK: migrateSupportDirectory

    private func makeTempSupport() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("barktor-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func movesLegacyTreeAndRenamesMeetingsFolder() throws {
        let fm = FileManager.default
        let support = try makeTempSupport()
        defer { try? fm.removeItem(at: support) }
        let old = support.appendingPathComponent("Purr", isDirectory: true)
        try fm.createDirectory(
            at: old.appendingPathComponent("models"), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: old.appendingPathComponent("Purr Meetings"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(
            to: old.appendingPathComponent("Purr Meetings/meeting.md"))

        LegacyMigration.migrateSupportDirectory(at: support, fm: fm)

        let new = support.appendingPathComponent("Barktor", isDirectory: true)
        let oldGone = !fm.fileExists(atPath: old.path)
        let modelsMoved = fm.fileExists(atPath: new.appendingPathComponent("models").path)
        let meetingMoved = fm.fileExists(
            atPath: new.appendingPathComponent("Meetings/meeting.md").path)
        #expect(oldGone)
        #expect(modelsMoved)
        #expect(meetingMoved)
    }

    @Test func neverTouchesAnExistingBarktorTree() throws {
        let fm = FileManager.default
        let support = try makeTempSupport()
        defer { try? fm.removeItem(at: support) }
        let old = support.appendingPathComponent("Purr", isDirectory: true)
        let new = support.appendingPathComponent("Barktor", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: new.appendingPathComponent("history.json"))

        LegacyMigration.migrateSupportDirectory(at: support, fm: fm)

        let legacyStays = fm.fileExists(atPath: old.path)
        let newKept = fm.fileExists(atPath: new.appendingPathComponent("history.json").path)
        #expect(legacyStays)
        #expect(newKept)
    }

    @Test func replacesABarktorScaffoldThatHoldsNoFiles() throws {
        let fm = FileManager.default
        let support = try makeTempSupport()
        defer { try? fm.removeItem(at: support) }
        let old = support.appendingPathComponent("Purr", isDirectory: true)
        let new = support.appendingPathComponent("Barktor", isDirectory: true)
        try fm.createDirectory(
            at: old.appendingPathComponent("models"), withIntermediateDirectories: true)
        try Data("weights".utf8).write(
            to: old.appendingPathComponent("models/weights.bin"))
        // Empty scaffold (directories only, no files), as left behind by a
        // launch that created Barktor/models before migration got to run.
        try fm.createDirectory(
            at: new.appendingPathComponent("models"), withIntermediateDirectories: true)

        LegacyMigration.migrateSupportDirectory(at: support, fm: fm)

        let oldGone = !fm.fileExists(atPath: old.path)
        let weightsMoved = fm.fileExists(
            atPath: new.appendingPathComponent("models/weights.bin").path)
        #expect(oldGone)
        #expect(weightsMoved)
    }

    @Test func noopWhenThereIsNothingToMigrate() throws {
        let fm = FileManager.default
        let support = try makeTempSupport()
        defer { try? fm.removeItem(at: support) }

        LegacyMigration.migrateSupportDirectory(at: support, fm: fm)

        let created = fm.fileExists(
            atPath: support.appendingPathComponent("Barktor").path)
        #expect(!created)
    }
}
