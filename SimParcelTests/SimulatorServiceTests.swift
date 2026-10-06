import Foundation
import Testing

struct SimulatorServiceTests {
    private enum ImportError: Error {
        case failed
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    @Test func stagesLivePhotoTogetherAndKeepsOriginals() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("IMG_3926.HEIC")
        let video = root.appendingPathComponent("IMG_3926.MOV")
        let photoData = Data("photo metadata".utf8)
        let videoData = Data("video metadata".utf8)
        try photoData.write(to: photo)
        try videoData.write(to: video)

        let files = try await SimulatorService.withStagedFiles([photo, video], temporaryDirectory: root) { files in
            #expect(files.map(\.lastPathComponent) == ["IMG_3926.HEIC", "IMG_3926.MOV"])
            #expect(files[0].deletingLastPathComponent() == files[1].deletingLastPathComponent())
            #expect(files[0] != photo && files[1] != video)
            let copiedPhoto = try Data(contentsOf: files[0])
            let copiedVideo = try Data(contentsOf: files[1])
            #expect(copiedPhoto == photoData)
            #expect(copiedVideo == videoData)
            await Task.yield()
            #expect(FileManager.default.fileExists(atPath: files[0].path))
            return files
        }

        #expect(!FileManager.default.fileExists(atPath: files[0].deletingLastPathComponent().path))
        #expect(try Data(contentsOf: photo) == photoData)
        #expect(try Data(contentsOf: video) == videoData)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["IMG_3926.HEIC", "IMG_3926.MOV"])
    }

    @Test func cleansUpAfterImportFailure() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        try Data("photo".utf8).write(to: source)

        await #expect(throws: ImportError.self) {
            try await SimulatorService.withStagedFiles([source], temporaryDirectory: root) { files in
                #expect(FileManager.default.fileExists(atPath: files[0].path))
                throw ImportError.failed
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["photo.png"])
    }

    @Test func cleansUpPartialCopiesBeforeImport() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        let missing = root.appendingPathComponent("missing.mov")
        try Data("photo".utf8).write(to: source)

        await #expect(throws: SimulatorServiceError.self) {
            try await SimulatorService.withStagedFiles([source, missing], temporaryDirectory: root) { _ in
                Issue.record("Import must not run when a source could not be copied.")
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["photo.png"])
    }

    @Test func isolatesCopiesForMultipleImports() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        let data = Data("photo".utf8)
        try data.write(to: source)

        let operation: @Sendable ([URL]) async throws -> URL = { files in
            await Task.yield()
            let copy = try Data(contentsOf: files[0])
            #expect(copy == data)
            return files[0]
        }
        async let first = SimulatorService.withStagedFiles([source], temporaryDirectory: root, operation: operation)
        async let second = SimulatorService.withStagedFiles([source], temporaryDirectory: root, operation: operation)
        let (firstURL, secondURL) = try await (first, second)

        #expect(firstURL.deletingLastPathComponent() != secondURL.deletingLastPathComponent())
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["photo.png"])
    }

    @Test func cleansUpWhenImportIsCancelled() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.png")
        try Data("photo".utf8).write(to: source)

        await #expect(throws: CancellationError.self) {
            try await SimulatorService.withStagedFiles([source], temporaryDirectory: root) { _ in
                throw CancellationError()
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["photo.png"])
    }

    @Test func stagesTheContentsOfASymbolicLink() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.png")
        let link = root.appendingPathComponent("linked.png")
        let data = Data("photo".utf8)
        try data.write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)

        try await SimulatorService.withStagedFiles([link], temporaryDirectory: root) { files in
            let values = try files[0].resourceValues(forKeys: [.isSymbolicLinkKey])
            let copy = try Data(contentsOf: files[0])
            #expect(files[0].lastPathComponent == "linked.png")
            #expect(values.isSymbolicLink == false)
            #expect(copy == data)
        }
        #expect(try Data(contentsOf: original) == data)
        #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func explainsInvalidMediaWithoutAssumingPermissionDenial() {
        let output = """
        Failed to import '/Downloads/photo.png', error [PHPhotosErrorDomain] 3302: The operation couldn’t be completed.
        An error was encountered processing the command (domain=com.apple.CoreSimulator.LaunchdSimError, code=133):
        Multiple errors were returned; see stderr
        """
        let message = SimulatorService.conciseMessage(output)
        #expect(message.hasPrefix("Photos couldn’t import this file."))
        #expect(!message.contains("Inaccessible"))
        #expect(!message.contains("permission"))
        #expect(SimulatorService.conciseMessage("Underlying error (domain=PHPhotosErrorDomain, code=3302):") == message)
    }

    @Test func explainsUnauthorizedPush() {
        let output = """
        An error was encountered processing the command (domain=UNErrorDomain, code=2003):
        Simulator device failed to complete the requested operation.
        Underlying error (domain=UNErrorDomain, code=2003):
        \tRepository could not save notification. Source is not authorized.
        """

        #expect(SimulatorService.conciseMessage(output).hasPrefix("The app isn’t allowed to show notifications."))
    }

    @Test func keepsTheInnermostUnderlyingError() {
        let output = """
        An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):
        Unable to lookup in current state: Shutdown
        Underlying error (domain=NSPOSIXErrorDomain, code=22):
        \tInvalid argument
        """

        #expect(SimulatorService.conciseMessage(output) == "Invalid argument")
    }

    @Test func extractsTheReasonFromACrash() {
        let output = """
        *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'Invalid domain=nil'
        *** First throw call stack:
        (
        \t0   CoreFoundation   0x00000001840ae8c0 __exceptionPreprocess + 176
        )
        """

        #expect(SimulatorService.conciseMessage(output) == "simctl crashed: Invalid domain=nil")
    }

    @Test func shortensPlainOutput() {
        #expect(SimulatorService.conciseMessage("one\ntwo") == "one\ntwo")
        #expect(SimulatorService.conciseMessage("1\n2\n3\n4\n5") == "1\n2\n3…")
    }
}
