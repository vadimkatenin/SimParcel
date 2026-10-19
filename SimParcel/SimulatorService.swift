import Foundation

enum SimulatorServiceError: LocalizedError {
    case commandFailed(String)
    case invalidResponse
    case canvasDeviceUnavailable
    case canvasManagedByXcode
    case applicationMissing(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message):
            message
        case .invalidResponse:
            String(localized: "simulators.invalidResponseError")
        case .canvasDeviceUnavailable:
            String(localized: "simulators.canvas.unavailableError")
        case .canvasManagedByXcode:
            String(localized: "simulators.canvas.managedHint")
        case .applicationMissing(let path):
            String(format: String(localized: "simulators.applicationMissingError"), path)
        }
    }
}

struct SimulatorService: SimulatorServicing {
    private let commandRunner: any SimulatorCommandRunning
    private static let invalidMediaMessage = "Photos couldn’t import this file. Check that it is a supported photo or video and isn’t damaged."

    init(commandRunner: any SimulatorCommandRunning = SimulatorCommandRunner()) {
        self.commandRunner = commandRunner
    }

    /// Lists ordinary devices and only booted Canvas devices; a missing preview set is optional.
    func availableDevices() async throws -> [SimulatorDevice] {
        async let standard = devices(in: .standard)
        async let previews = try? devices(in: .previews)
        return try await standard + (previews ?? []).filter(\.isBooted)
    }

    /// Boots the device unless it is already running, then shows it in Simulator.
    ///
    /// The state is read again here because the device may have been started or shut down
    /// since the list was last refreshed.
    func bootIfNeeded(_ device: SimulatorDevice) async throws {
        let isBooted = try await devices(in: device.deviceSet).first { $0.id == device.id }?.isBooted ?? false
        if device.deviceSet == .previews {
            guard isBooted else {
                throw SimulatorServiceError.canvasDeviceUnavailable
            }

            return
        }

        guard !isBooted else {
            return
        }

        _ = try await simctl(["bootstatus", device.udid, "-b"], in: device.deviceSet)
        try? await openSimulatorApp(showing: device)
    }

    /// Starts and opens ordinary simulators while leaving Canvas lifecycle under Xcode control.
    func show(_ device: SimulatorDevice) async throws {
        guard device.deviceSet == .standard else {
            throw SimulatorServiceError.canvasManagedByXcode
        }

        _ = try await simctl(["bootstatus", device.udid, "-b"], in: device.deviceSet)
        try await openSimulatorApp(showing: device)
    }

    /// Sends a queue item with the `simctl` command for its kind.
    func send(_ item: QueueItem, to device: SimulatorDevice) async throws {
        // simctl crashes instead of reporting an error when a file is missing.
        if let missing = item.urls.first(where: { $0.isFileURL && !FileManager.default.fileExists(atPath: $0.path) }) {
            throw SimulatorServiceError.commandFailed("\(missing.lastPathComponent) no longer exists.")
        }

        if device.deviceSet == .previews {
            try await bootIfNeeded(device)
        }

        switch item.kind {
        case .photo, .video, .livePhoto, .contact:
            try await Self.withStagedFiles(item.urls) { files in
                // One call for all files, so a Live Photo's image and video are paired.
                do {
                    _ = try await simctl(["addmedia", device.udid] + files.map(\.path), in: device.deviceSet)
                } catch SimulatorServiceError.commandFailed(let message) {
                    throw SimulatorServiceError.commandFailed(
                        Self.mediaImportMessage(message, files: files, sources: item.urls)
                    )
                }
            }
        case .app:
            _ = try await simctl(["install", device.udid, item.urls[0].path], in: device.deviceSet)
        case .push:
            let payload = item.urls[0]
            try PushPayload.validate(try Data(contentsOf: payload))
            _ = try await simctl(["push", device.udid, payload.path], in: device.deviceSet)
        case .link:
            _ = try await simctl(["openurl", device.udid, item.urls[0].absoluteString], in: device.deviceSet)
        case .file:
            try FilesStorage.copy(item.urls[0], into: try await filesFolder(on: device))
        }
    }

    /// CoreSimulator may not be able to read files in protected folders such as Downloads,
    /// even when SimParcel can. Keep copies in an unprotected folder until addmedia finishes.
    static func withStagedFiles<Result: Sendable>(
        _ sources: [URL],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        operation: @Sendable ([URL]) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let folder = temporaryDirectory.appendingPathComponent("SimParcel-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: folder,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SimulatorServiceError.commandFailed("Could not prepare files for import: \(error.localizedDescription)")
        }
        defer {
            try? fileManager.removeItem(at: folder)
        }

        let files = try sources.map { source in
            try Task.checkCancellation()
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            do {
                try fileManager.copyItem(at: source.resolvingSymlinksInPath(), to: destination)
                // Finder's Locked flag is copied too. Only unlock the disposable copy.
                try fileManager.setAttributes([.immutable: false], ofItemAtPath: destination.path)
            } catch {
                throw SimulatorServiceError.commandFailed(
                    "Could not prepare \(source.lastPathComponent) for import: \(error.localizedDescription)"
                )
            }

            return destination
        }
        try Task.checkCancellation()
        return try await operation(files)
    }

    /// Invalid media can make newer simctl versions crash while constructing the Photos error.
    /// Keep this fallback specific to addmedia; the same exception elsewhere is still a crash.
    static func mediaImportMessage(_ message: String, files: [URL], sources: [URL]) -> String {
        if message.contains("simctl crashed: Invalid domain=nil in -[NSError initWithDomain:code:userInfo:]") {
            return invalidMediaMessage
        }

        return zip(files, sources).reduce(message) { message, pair in
            message.replacingOccurrences(of: pair.0.path, with: pair.1.path)
        }
    }

    /// Resolves the device application belonging to the selected Xcode installation.
    func simulatorApplication() async throws -> SimulatorApplication {
        let developerDirectory = try await commandRunner.output("/usr/bin/xcode-select", ["-p"])
        let path = String(decoding: developerDirectory, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let developerURL = URL(fileURLWithPath: path, isDirectory: true)
        let simulatorApp = developerURL.appendingPathComponent("Applications/Simulator.app")
        let deviceHubApp = developerURL.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app")

        if FileManager.default.fileExists(atPath: simulatorApp.path) {
            return .simulator(simulatorApp)
        } else if FileManager.default.fileExists(atPath: deviceHubApp.path) {
            return .deviceHub(deviceHubApp)
        } else {
            throw SimulatorServiceError.applicationMissing(path)
        }
    }

    /// Keeps error output readable: simctl sometimes crashes and prints an exception with a full stack trace,
    /// and otherwise puts the useful part in the innermost "Underlying error" line.
    static func conciseMessage(_ output: String) -> String {
        if output.contains("Source is not authorized") {
            return "The app isn’t allowed to show notifications. Open it in the simulator, allow notifications, then try again."
        }

        if output.contains("[PHPhotosErrorDomain] 3302") || output.contains("domain=PHPhotosErrorDomain, code=3302") {
            return invalidMediaMessage
        }

        if let reason = output.range(of: "reason: '"),
           let end = output[reason.upperBound...].firstIndex(of: "'") {
            return "simctl crashed: \(output[reason.upperBound..<end])"
        }

        let lines = output.split(whereSeparator: \.isNewline)
        if let detail = lines.last(where: { $0.hasPrefix("\t") }) {
            return detail.trimmingCharacters(in: .whitespaces)
        }

        return lines.prefix(3).joined(separator: "\n") + (lines.count > 3 ? "…" : "")
    }

    private func devices(in deviceSet: SimulatorDeviceSet) async throws -> [SimulatorDevice] {
        let output = try await simctl(["list", "devices", "available", "--json"], in: deviceSet)
        do {
            return try SimulatorList.parse(output, deviceSet: deviceSet)
        } catch {
            throw SimulatorServiceError.invalidResponse
        }
    }

    /// The Files app's On My iPhone folder on a device.
    private func filesFolder(on device: SimulatorDevice) async throws -> URL {
        let groups = try? await simctl(["get_app_container", device.udid, "com.apple.DocumentsApp", "groups"], in: device.deviceSet)
        let group = groups
            .flatMap { FilesStorage.groupPath(inGroupsOutput: String(decoding: $0, as: UTF8.self)) }
            .map { URL(fileURLWithPath: $0) }
            ?? device.dataPath.flatMap(FilesStorage.findGroup(inDataPath:))

        guard let group else {
            throw SimulatorServiceError.commandFailed("The Files app isn’t available on \(device.name).")
        }

        return group.appendingPathComponent(FilesStorage.folderName)
    }

    private func openSimulatorApp(showing device: SimulatorDevice) async throws {
        switch try await simulatorApplication() {
        case .simulator(let app):
            _ = try await commandRunner.output("/usr/bin/open", ["-a", app.path, "--args", "-CurrentDeviceUDID", device.udid])
        case .deviceHub(let app):
            _ = try await commandRunner.output("/usr/bin/open", ["-a", app.path, "devices://manage/select?id=\(device.udid)"])
        }
    }

    private func simctl(_ arguments: [String], in deviceSet: SimulatorDeviceSet = .standard) async throws -> Data {
        try await commandRunner.output("/usr/bin/xcrun", ["simctl"] + deviceSet.arguments(for: arguments))
    }
}
