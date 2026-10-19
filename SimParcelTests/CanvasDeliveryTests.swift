import Foundation
import Testing

struct CanvasDeliveryTests {
    @Test func excludesStoppedCanvasDevicesAndToleratesMissingPreviewSet() async throws {
        let runner = try CommandStub()
        let service = SimulatorService(commandRunner: runner)
        let devices = try await service.availableDevices()
        #expect(devices.allSatisfy { $0.deviceSet == .standard })

        await runner.failPreviews(true)
        let withoutPreviewSet = try await service.availableDevices()
        #expect(withoutPreviewSet == devices)
    }

    @Test func doesNotHideStandardListingFailures() async throws {
        let runner = try CommandStub()
        await runner.failStandard(true)
        await #expect(throws: SimulatorServiceError.self) {
            try await SimulatorService(commandRunner: runner).availableDevices()
        }
    }

    @Test func neverBootsOrShowsCanvasDevices() async throws {
        let runner = try CommandStub()
        let service = SimulatorService(commandRunner: runner)
        let preview = try SimulatorFixtures.device(in: .previews)
        await #expect(throws: SimulatorServiceError.self) {
            try await service.bootIfNeeded(preview)
        }
        await #expect(throws: SimulatorServiceError.self) {
            try await service.show(preview)
        }

        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["simctl", "--set", "previews", "list", "devices", "available", "--json"])
    }

    @Test func rechecksCanvasStateBeforeDelivery() async throws {
        let runner = try CommandStub()
        let preview = try SimulatorFixtures.device(in: .previews)
        let link = QueueItem(url: try #require(URL(string: "https://example.com")))
        await #expect(throws: SimulatorServiceError.self) {
            try await SimulatorService(commandRunner: runner).send(link, to: preview)
        }

        #expect(await runner.calls.count == 1)
    }

    @Test func routesLinksAndPushesToThePreviewSetWithRawUDID() async throws {
        let runner = try CommandStub()
        await runner.bootPreviews()
        let service = SimulatorService(commandRunner: runner)
        let preview = try SimulatorFixtures.device(in: .previews)
        let link = QueueItem(url: try #require(URL(string: "https://example.com")))
        try await service.send(link, to: preview)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let payload = folder.appendingPathComponent("notification.apns")
        try Data(#"{"Simulator Target Bundle":"com.example.MyApp","aps":{"alert":"Hello"}}"#.utf8).write(to: payload)
        try await service.send(QueueItem(url: payload), to: preview)

        let commands = await runner.calls.map(\.arguments)
        #expect(commands.contains(["simctl", "--set", "previews", "openurl", preview.udid, "https://example.com"]))
        #expect(commands.contains(["simctl", "--set", "previews", "push", preview.udid, payload.path]))
        #expect(!commands.flatMap { $0 }.contains(preview.id))
    }

    @Test func routesMediaInstallationAndFilesToThePreviewSet() async throws {
        let runner = try CommandStub()
        await runner.bootPreviews()
        let service = SimulatorService(commandRunner: runner)
        let preview = try SimulatorFixtures.device(in: .previews)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let photo = repository.appendingPathComponent("Artwork/AppIcon-Source.png")
        try await service.send(QueueItem(url: photo), to: preview)

        let application = folder.appendingPathComponent("SimParcel.app")
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
        try await service.send(QueueItem(url: application), to: preview)

        await runner.useFilesGroup(folder.path)
        let source = repository.appendingPathComponent("README.md")
        try await service.send(QueueItem(url: source), to: preview)
        let destination = folder.appendingPathComponent(FilesStorage.folderName).appendingPathComponent("README.md")
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))

        let commands = await runner.calls.map(\.arguments)
        #expect(commands.contains { $0.starts(with: ["simctl", "--set", "previews", "addmedia", preview.udid]) })
        #expect(commands.contains(["simctl", "--set", "previews", "install", preview.udid, application.path]))
        #expect(commands.contains(["simctl", "--set", "previews", "get_app_container", preview.udid, "com.apple.DocumentsApp", "groups"]))
        #expect(!commands.flatMap { $0 }.contains(preview.id))
    }

    @Test func detectsLegacySimulatorAndDeviceHubAndBuildsTheirLaunchCommands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let developerDirectory = folder.appendingPathComponent("Contents/Developer")
        let hub = folder.appendingPathComponent("Contents/Applications/DeviceHub.app")
        let simulator = developerDirectory.appendingPathComponent("Applications/Simulator.app")
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let runner = try CommandStub(developerDirectory: developerDirectory.path)
        let service = SimulatorService(commandRunner: runner)
        let device = try SimulatorFixtures.device(in: .standard)
        guard case .deviceHub(let detectedHub) = try await service.simulatorApplication() else {
            Issue.record("Device Hub was not detected.")
            return
        }

        #expect(detectedHub.path == hub.path)
        try await service.show(device)
        #expect(await runner.calls.contains { $0.executable == "/usr/bin/open" && $0.arguments == ["-a", hub.path, "devices://manage/select?id=\(device.udid)"] })

        try FileManager.default.createDirectory(at: simulator, withIntermediateDirectories: true)
        guard case .simulator(let detectedSimulator) = try await service.simulatorApplication() else {
            Issue.record("The legacy Simulator was not detected.")
            return
        }

        #expect(detectedSimulator.path == simulator.path)
        try await service.show(device)
        #expect(await runner.calls.contains { $0.executable == "/usr/bin/open" && $0.arguments == ["-a", simulator.path, "--args", "-CurrentDeviceUDID", device.udid] })
    }

    private struct Command: Sendable {
        let executable: String
        let arguments: [String]
    }

    private actor CommandStub: SimulatorCommandRunning {
        private let standard: Data
        private var previews: Data
        private let developerDirectory: String
        private var standardFails = false
        private var previewsFail = false
        private var filesGroup: String?
        private(set) var calls: [Command] = []

        init(developerDirectory: String = "/Applications/Xcode_27.app/Contents/Developer") throws {
            standard = try SimulatorFixtures.response(for: .standard)
            previews = try SimulatorFixtures.response(for: .previews)
            self.developerDirectory = developerDirectory
        }

        func output(_ executable: String, _ arguments: [String]) async throws -> Data {
            calls.append(Command(executable: executable, arguments: arguments))
            if executable == "/usr/bin/xcode-select" {
                return Data(developerDirectory.utf8)
            }

            if arguments.contains("list") {
                if arguments.contains("--set") {
                    if previewsFail {
                        throw SimulatorServiceError.invalidResponse
                    }

                    return previews
                }

                if standardFails {
                    throw SimulatorServiceError.invalidResponse
                }

                return standard
            }

            if arguments.contains("get_app_container"), let filesGroup {
                return Data("group.com.apple.FileProvider.LocalStorage\t\(filesGroup)\n".utf8)
            }

            return Data()
        }

        func failStandard(_ fails: Bool) {
            standardFails = fails
        }

        func failPreviews(_ fails: Bool) {
            previewsFail = fails
        }

        func bootPreviews() {
            previews = Data(String(decoding: previews, as: UTF8.self).replacingOccurrences(of: "Shutdown", with: "Booted").utf8)
        }

        func useFilesGroup(_ path: String) {
            filesGroup = path
        }
    }
}
