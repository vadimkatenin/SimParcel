import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle
        case info(String, detail: String? = nil)
        case working(String)
        case success(String)
        case failure(String, detail: String? = nil)
    }

    /// Selection value that sends items to every running simulator.
    static let allRunningID = "all-running"
    private static let selectedDeviceKey = "selectedSimulatorID"

    private(set) var devices: [SimulatorDevice] = []
    private(set) var items: [QueueItem] = []
    private(set) var isRefreshing = false
    private(set) var isSending = false
    private(set) var sendingItemID: QueueItem.ID?
    private(set) var completedSteps = 0
    private(set) var totalSteps = 0
    private(set) var status: Status = .idle
    var isFilePickerPresented = false
    var isLinkPromptPresented = false

    var selectedDeviceID: String = UserDefaults.standard.string(forKey: AppModel.selectedDeviceKey) ?? "" {
        didSet {
            UserDefaults.standard.set(selectedDeviceID, forKey: Self.selectedDeviceKey)
        }
    }

    var shutdownRuntimeGroups: [SimulatorRuntimeGroup] {
        SimulatorList.shutdownGroups(in: devices)
    }

    var runningDevices: [SimulatorDevice] {
        SimulatorList.runningDevices(in: devices)
    }

    var isAllRunningSelected: Bool {
        selectedDeviceID == Self.allRunningID
    }

    var selectedDevice: SimulatorDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    /// The simulators that the next send goes to.
    var targets: [SimulatorDevice] {
        if isAllRunningSelected {
            return runningDevices
        }

        return selectedDevice.map { [$0] } ?? []
    }

    var isBusy: Bool {
        isRefreshing || isSending
    }

    var canSend: Bool {
        !items.isEmpty && !targets.isEmpty && !isBusy
    }

    var failedCount: Int {
        items.filter { $0.failure != nil }.count
    }

    func refreshDevices() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
        }

        do {
            devices = try await SimulatorService.availableDevices()

            if selectedDevice == nil && !isAllRunningSelected {
                selectedDeviceID = SimulatorList.preferredDevice(in: devices)?.id ?? ""
            }

            if devices.isEmpty {
                status = .failure("No iOS simulators found. Install an iOS runtime in Xcode, then refresh.")
            } else if case .failure = status, failedCount == 0 {
                status = .idle
            }
        } catch {
            status = .failure("Could not list simulators: \(error.localizedDescription)")
        }
    }

    func add(_ urls: [URL]) async {
        guard !isSending, !urls.isEmpty else {
            return
        }

        let (supported, skipped) = await Task.detached(priority: .userInitiated) {
            DroppedFiles.collect(from: urls)
        }.value

        items = QueueItem.merging(supported, into: items)

        if let summary = DroppedFiles.skippedSummary(skipped, addedAny: !supported.isEmpty) {
            status = supported.isEmpty
                ? .failure(summary.message, detail: summary.detail)
                : .info(summary.message, detail: summary.detail)
        } else {
            status = .idle
        }
    }

    /// Adds a typed web link or deep link, such as `https://example.com` or `myapp://settings`.
    func addLink(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty, !url.isFileURL else {
            status = .failure("“\(trimmed)” isn’t a valid link. Include a scheme, such as https:// or myapp://.")
            return
        }

        await add([url])
    }

    func reportFilePickerError(_ error: Error) {
        status = .failure("Could not open files: \(error.localizedDescription)")
    }

    func remove(_ item: QueueItem) {
        guard !isSending else {
            return
        }

        items.removeAll { $0.id == item.id }
        if items.isEmpty {
            status = .idle
        }
    }

    func removeAll() {
        guard !isSending else {
            return
        }

        items.removeAll()
        status = .idle
    }

    func sendAll() async {
        let targets = targets
        guard canSend else {
            return
        }

        isSending = true
        completedSteps = 0
        totalSteps = items.count * targets.count
        status = .working("Sending…")
        defer {
            isSending = false
            sendingItemID = nil
        }

        if targets.count == 1, let device = targets.first {
            do {
                if !device.isBooted {
                    status = .working("Starting \(device.name)…")
                }
                try await SimulatorService.bootIfNeeded(device)
            } catch {
                status = .failure("Could not start \(device.name): \(error.localizedDescription)")
                return
            }
        }

        var succeeded = 0
        var lastFailure: String?

        for item in items.sorted(by: { $0.kind.sendOrder < $1.kind.sendOrder }) {
            sendingItemID = item.id
            var failures: [String] = []

            for device in targets {
                status = .working("Sending \(completedSteps + 1) of \(totalSteps)…")

                do {
                    try await SimulatorService.send(item, to: device)
                } catch {
                    let message = error.localizedDescription
                    failures.append(targets.count > 1 ? "\(device.name): \(message)" : message)
                }

                completedSteps += 1
            }

            if failures.isEmpty {
                items.removeAll { $0.id == item.id }
                succeeded += 1
            } else if let index = items.firstIndex(where: { $0.id == item.id }) {
                let message = failures.joined(separator: "\n")
                items[index].failure = message
                lastFailure = message
            }
        }

        let noun = succeeded == 1 ? "item" : "items"
        let destination = targets.count == 1 ? targets[0].name : "\(targets.count) simulators"
        if let lastFailure {
            let failed = items.filter { $0.failure != nil }.count
            let reason = failed == 1 ? ": \(lastFailure.split(whereSeparator: \.isNewline).first ?? "")" : "."
            status = .failure("Sent \(succeeded) \(noun). \(failed) failed\(reason)", detail: lastFailure)
        } else {
            status = .success("Sent \(succeeded) \(noun) to \(destination).")
        }

        await refreshDevices()
    }

    func showSelectedDevice() async {
        guard let device = selectedDevice, !isBusy else {
            return
        }

        isSending = true
        defer {
            isSending = false
        }

        if !device.isBooted {
            status = .working("Starting \(device.name)…")
        }

        do {
            try await SimulatorService.show(device)
            if case .working = status {
                status = .idle
            }
        } catch {
            status = .failure("Could not open \(device.name): \(error.localizedDescription)")
        }

        await refreshDevices()
    }
}
