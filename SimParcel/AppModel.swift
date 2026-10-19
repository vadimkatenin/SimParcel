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
    static let allPreviewsID = "all-previews"

    private(set) var devices: [SimulatorDevice] = []
    private(set) var simulatorApplication: SimulatorApplication?
    private(set) var items: [QueueItem] = []
    private(set) var isRefreshing = false
    private(set) var isSending = false
    private(set) var sendingItemID: QueueItem.ID?
    private(set) var completedSteps = 0
    private(set) var totalSteps = 0
    private(set) var status: Status = .idle
    var isFilePickerPresented = false
    var isLinkPromptPresented = false

    private let simulatorService: any SimulatorServicing
    private let selectionStore: any SimulatorSelectionStoring

    var selectedDeviceID: String {
        didSet {
            selectionStore.selectedSimulatorID = selectedDeviceID
        }
    }

    var shutdownRuntimeGroups: [SimulatorRuntimeGroup] {
        SimulatorList.shutdownGroups(in: devices.filter { $0.deviceSet == .standard })
    }

    var runningDevices: [SimulatorDevice] {
        SimulatorList.runningDevices(in: devices.filter { $0.deviceSet == .standard })
    }

    var bootedCanvasDevices: [SimulatorDevice] {
        SimulatorList.runningDevices(in: devices.filter { $0.deviceSet == .previews })
    }

    var isAllPreviewsSelected: Bool {
        selectedDeviceID == Self.allPreviewsID
    }

    var isCanvasDestinationSelected: Bool {
        isAllPreviewsSelected || selectedDeviceID.hasPrefix("previews:")
    }

    var isBroadcastSelected: Bool {
        isAllRunningSelected || isAllPreviewsSelected
    }

    var canShowSelectedDevice: Bool {
        selectedDevice?.deviceSet == .standard && !isBusy
    }

    var isAllRunningSelected: Bool {
        selectedDeviceID == Self.allRunningID
    }

    var selectedDevice: SimulatorDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var showSimulatorTitle: String {
        if selectedDevice?.isBooted == false {
            return String(localized: "simulators.runButton")
        }

        return simulatorApplication?.showTitle ?? String(localized: "simulators.showButton")
    }

    var showSimulatorHelp: String {
        if isCanvasDestinationSelected {
            return String(localized: "simulators.canvas.managedHint")
        }

        if selectedDevice?.isBooted == false {
            return String(localized: "simulators.startHint")
        }

        return simulatorApplication?.showHelp ?? String(localized: "simulators.selectionHint")
    }

    /// The simulators that the next send goes to.
    var targets: [SimulatorDevice] {
        if isAllRunningSelected {
            return runningDevices
        }

        if isAllPreviewsSelected {
            return bootedCanvasDevices
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

    var targetStateText: String {
        if isBroadcastSelected {
            let running = targets
            guard !running.isEmpty else {
                return isAllPreviewsSelected
                    ? String(localized: "simulators.canvas.emptyState")
                    : String(localized: "simulators.emptyRunningState")
            }

            let format = isAllPreviewsSelected
                ? String(localized: "simulators.canvas.broadcastState")
                : String(localized: "simulators.broadcastState")

            return String(format: format, running.count, running.map(\.name).joined(separator: ", "))
        }

        guard let device = selectedDevice else {
            return isCanvasDestinationSelected
                ? String(localized: "simulators.canvas.unavailableState")
                : String(localized: "simulators.selectionPlaceholder")
        }

        let format: String
        if !device.isBooted {
            format = String(localized: "simulators.stoppedState")
        } else if device.deviceSet == .previews {
            format = String(localized: "simulators.canvas.targetState")
        } else {
            format = String(localized: "simulators.runningState")
        }

        return String(format: format, device.runtime.name)
    }

    var sendTitle: String {
        let count = targets.count
        let isCanvas = isCanvasDestinationSelected
        if isBroadcastSelected && count > 1 {
            let format = isCanvas
                ? String(localized: "simulators.canvas.sendManyButton")
                : String(localized: "simulators.sendManyButton")

            return String(format: format, count)
        }

        return isCanvas
            ? String(localized: "simulators.canvas.sendButton")
            : String(localized: "simulators.sendButton")
    }

    var idleStatusMessage: String {
        if targets.isEmpty && (isBroadcastSelected || isCanvasDestinationSelected) {
            return isCanvasDestinationSelected
                ? String(localized: "simulators.canvas.startHint")
                : String(localized: "simulators.emptyTargetHint")
        }

        switch items.count {
        case 0:
            return String(localized: "queue.emptyStatus")
        case 1:
            return String(localized: "queue.readyItemStatus")
        default:
            return String(format: String(localized: "queue.readyItemsStatus"), items.count)
        }
    }

    init(
        simulatorService: any SimulatorServicing = SimulatorService(),
        selectionStore: any SimulatorSelectionStoring = UserDefaults.standard
    ) {
        self.simulatorService = simulatorService
        self.selectionStore = selectionStore
        selectedDeviceID = selectionStore.selectedSimulatorID
    }

    func refreshDevices(preservingStatus: Bool = false) async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        if !preservingStatus, failedCount == 0, case .failure = status {
            status = .idle
        }

        defer {
            isRefreshing = false
        }

        do {
            simulatorApplication = try? await simulatorService.simulatorApplication()
            devices = try await simulatorService.availableDevices()

            if selectedDevice == nil && !isBroadcastSelected && !isCanvasDestinationSelected {
                selectedDeviceID = SimulatorList.preferredDevice(in: devices)?.id ?? ""
            }

            if devices.isEmpty {
                status = .failure(String(localized: "simulators.emptyError"))
            } else if !preservingStatus, case .failure = status, failedCount == 0 {
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
                try await simulatorService.bootIfNeeded(device)
            } catch {
                status = .failure("Could not start \(device.name): \(error.localizedDescription)")
                return
            }
        }

        var succeeded = 0
        var lastFailure: String?

        for item in items.sorted(by: { $0.kind.sendOrder < $1.kind.sendOrder }) {
            guard !Task.isCancelled else {
                status = .idle
                return
            }

            sendingItemID = item.id
            var failures: [String] = []

            for device in targets {
                guard !Task.isCancelled else {
                    status = .idle
                    return
                }

                status = .working("Sending \(completedSteps + 1) of \(totalSteps)…")

                do {
                    try await simulatorService.send(item, to: device)
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
        let destination: String
        if targets.count == 1 {
            destination = targets[0].label
        } else {
            let format = isAllPreviewsSelected
                ? String(localized: "simulators.canvas.destinationLabel")
                : String(localized: "simulators.destinationLabel")
            destination = String(format: format, targets.count)
        }

        if let lastFailure {
            let failed = items.filter { $0.failure != nil }.count
            let reason = failed == 1 ? ": \(lastFailure.split(whereSeparator: \.isNewline).first ?? "")" : "."
            status = .failure("Sent \(succeeded) \(noun). \(failed) failed\(reason)", detail: lastFailure)
        } else {
            status = .success("Sent \(succeeded) \(noun) to \(destination).")
        }

        await refreshDevices(preservingStatus: true)
    }

    func showSelectedDevice() async {
        guard let device = selectedDevice, canShowSelectedDevice else {
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
            try await simulatorService.show(device)
            status = .idle
        } catch {
            status = .failure("Could not open \(device.name): \(error.localizedDescription)")
        }

        await refreshDevices(preservingStatus: true)
    }
}
