import AppKit
import NotesCore
import Vision
import XCTest
@testable import EdgeNotes

final class NotesSidebarTests: XCTestCase {
    func testDeletingFolderKeepsAttachmentsAndRestoresOnlyItsPreviouslyActiveNotes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.addFolder("Work")
            let folder = try XCTUnwrap(model.folder)
            model.newNote("active")
            let active = try XCTUnwrap(model.selected)
            model.change(active) { $0.attachments.append(NoteAttachment(name: "fixture.txt", data: Data("keep".utf8))) }
            model.newNote("already deleted")
            let deleted = try XCTUnwrap(model.selected)
            model.toggleNoteTrash(deleted)
            XCTAssertTrue(model.deleteFolder(folder))
            XCTAssertFalse(model.activeFolders.contains { $0.id == folder })
            XCTAssertFalse(model.openFolder(folder))
            XCTAssertEqual(model.trashCount, 2)
            XCTAssertEqual(model.document.notes.first { $0.id == active }?.attachments.first?.data, Data("keep".utf8))
            model.restoreFolder(folder)
            XCTAssertTrue(model.openFolder(folder))
            XCTAssertEqual(model.visible.map(\.id), [active])
            XCTAssertTrue(model.document.notes.first { $0.id == deleted }?.trashed == true)
            XCTAssertEqual(try NotesRepository(directory: directory).document, model.document)
        }
    }

    func testLastFolderDeletionAllowsNewNotesAndSingleNoteRestoreHasActiveDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("original")
            let note = try XCTUnwrap(model.selected)
            let folder = try XCTUnwrap(model.folder)
            XCTAssertTrue(model.deleteFolder(folder))
            XCTAssertTrue(model.activeFolders.isEmpty)
            model.toggleNoteTrash(note)
            XCTAssertEqual(model.activeFolders.count, 1)
            XCTAssertFalse(model.document.notes[0].trashed)
            XCTAssertNotEqual(model.document.notes[0].folderID, folder)
            model.newNote("new")
            XCTAssertEqual(model.document.notes.count, 2)
            XCTAssertEqual(model.selectedNote?.folderID, model.activeFolders[0].id)
            try model.document.validate()
        }
    }

    func testFolderDeletionRespectsFailedDraftSaveAndBackupMergeKeepsDeletedStatus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: target)
        }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("original")
            let folder = try XCTUnwrap(model.folder)
            model.draft = String(repeating: "x", count: 1_000_001)
            XCTAssertFalse(model.deleteFolder(folder))
            XCTAssertEqual(model.activeFolders.count, 1)
            XCTAssertFalse(model.document.notes[0].trashed)
            model.draft = "saved"
            XCTAssertTrue(model.deleteFolder(folder))
            let backup = try XCTUnwrap(model.repository).exportData()
            let imported = NotesModel(directory: target)
            try XCTUnwrap(imported.repository).importData(backup)
            imported.document = try XCTUnwrap(imported.repository).document
            XCTAssertEqual(imported.deletedFolders.count, 1)
            XCTAssertEqual(imported.document.notes[0].trashedWithFolder, true)
            imported.restoreFolder(imported.deletedFolders[0].id)
            XCTAssertFalse(imported.document.notes[0].trashed)
        }
    }

    func testOpenBarReceivesFirstBackgroundClickWithoutTogglingAgainOnMouseUp() async throws {
        try await MainActor.run {
            var actions = 0
            let bar = OpenBarView(activate: { actions += 1 }, changeSide: {})
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            XCTAssertTrue(bar.acceptsFirstMouse(for: event))
            bar.mouseDown(with: event)
            bar.mouseUp(with: event)
            XCTAssertEqual(actions, 1)
            XCTAssertTrue(bar.accessibilityPerformPress())
            XCTAssertEqual(actions, 2)
        }
    }
    func testOpenBarPaintReachesBothPhysicalEdgesAndNeverStartsWindowDragging() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let panel = OpenBarPanel(frame: NSRect(x: 0, y: 0, width: 10, height: 88))
            XCTAssertFalse(panel.isMovable)
            XCTAssertFalse(panel.isMovableByWindowBackground)
            XCTAssertFalse(panel.hidesOnDeactivate)
            XCTAssertFalse(panel.styleMask.contains(.resizable))
            XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.statusBar.rawValue)
            for side in [EdgePanelSide.left, .right] {
                let bar = OpenBarView(side: side, activate: {}, changeSide: {})
                let bitmap = try XCTUnwrap(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 88, bitsPerSample: 8,
                        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                        bytesPerRow: 0, bitsPerPixel: 0))
                let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                bar.draw(bar.bounds)
                NSGraphicsContext.restoreGraphicsState()
                let edge = side == .left ? 0 : 9
                for y in [12, 44, 75] {
                    XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: edge, y: y)).alphaComponent, 0.2)
                }
                XCTAssertFalse(bar.mouseDownCanMoveWindow)
            }
        }
    }
    func testFolderNavigationSavesDraftAndCountsExcludeTrash() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await MainActor.run {
            let model = NotesModel(directory: directory)
            XCTAssertTrue(model.showingFolders)
            let inbox = try XCTUnwrap(model.document.folders.first?.id)
            model.newNote("first")
            let first = try XCTUnwrap(model.selected)
            model.draft = "updated before navigation"
            XCTAssertTrue(model.showFolders())
            XCTAssertEqual(
                try NotesRepository(directory: directory).document.notes[0].text, "updated before navigation")
            XCTAssertTrue(model.draft.isEmpty)
            XCTAssertEqual(model.noteCount(in: inbox), 1)
            model.addFolder("Work")
            let work = try XCTUnwrap(model.folder)
            XCTAssertFalse(model.showingFolders)
            model.newNote("second")
            XCTAssertEqual(model.selectedNote?.folderID, work)
            model.change(first) { $0.trashed = true }
            XCTAssertEqual(model.noteCount(in: inbox), 0)
            XCTAssertEqual(model.noteCount(in: work), 1)
            XCTAssertEqual(model.activeNoteCount, 1)
            XCTAssertEqual(model.trashCount, 1)
            XCTAssertTrue(model.toggleTrash())
            XCTAssertEqual(model.visible.map(\.id), [first])
            XCTAssertTrue(model.toggleTrash())
            XCTAssertTrue(model.showingFolders)
            XCTAssertTrue(model.openFolder(work))
            XCTAssertEqual(model.visible.map(\.text), ["second"])
        }
    }

    func testFailedSavePreventsFolderSearchAndTrashNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("original")
            let selected = model.selected
            let folder = model.folder
            model.draft = String(repeating: "x", count: 1_000_001)
            XCTAssertFalse(model.showFolders())
            XCTAssertFalse(model.openFolder(nil))
            XCTAssertFalse(model.toggleSearch())
            XCTAssertFalse(model.toggleTrash())
            XCTAssertEqual(model.selected, selected)
            XCTAssertEqual(model.folder, folder)
            XCTAssertFalse(model.showingFolders)
            XCTAssertFalse(model.trash)
            XCTAssertFalse(model.searchVisible)
            XCTAssertEqual(model.draft.count, 1_000_001)
        }
    }

    func testGlobalSearchReturnsToFoldersWithoutLosingNotes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        await MainActor.run {
            let model = NotesModel(directory: directory)
            model.newNote("Coffee")
            model.addFolder("Work")
            model.newNote("Coffee meeting")
            XCTAssertTrue(model.showFolders())
            XCTAssertTrue(model.toggleSearch())
            model.search = "coffee"
            XCTAssertFalse(model.showingFolders)
            XCTAssertEqual(model.visible.count, 2)
            XCTAssertTrue(model.toggleSearch())
            XCTAssertTrue(model.showingFolders)
            XCTAssertEqual(model.document.notes.count, 2)
            let folder = model.document.folders[1].id
            model.renameFolder(folder, to: " Projects ")
            XCTAssertEqual(model.document.folders[1].name, "Projects")
            XCTAssertFalse(model.openFolder(UUID()))
        }
    }

}
