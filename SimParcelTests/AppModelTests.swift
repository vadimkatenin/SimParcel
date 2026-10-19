import Foundation
import Testing

@MainActor
struct AppModelTests {
    @Test func preservesShowFailureAndClearsItAfterSuccessfulRetry() async throws {
        let device = try SimulatorFixtures.device(in: .standard)
        let service = ServiceStub(devices: [device])
        let model = AppModel(simulatorService: service, selectionStore: SelectionStore(device.id))
        await model.refreshDevices()
        await service.failOpening(true)
        await model.showSelectedDevice()

        guard case .failure = model.status else {
            Issue.record("Automatic refresh erased the Show failure.")
            return
        }

        await service.failOpening(false)
        await model.showSelectedDevice()
        #expect(model.status == .idle)
        #expect(!model.isBusy)
    }

    @Test func reportsAnAutomaticRefreshFailure() async throws {
        let device = try SimulatorFixtures.device(in: .standard)
        let service = ServiceStub(devices: [device])
        let model = AppModel(simulatorService: service, selectionStore: SelectionStore(device.id))
        await model.refreshDevices()
        await service.failListing(true)
        await model.showSelectedDevice()

        guard case .failure(let message, _) = model.status else {
            Issue.record("The failed refresh must remain visible.")
            return
        }

        #expect(message.hasPrefix("Could not list simulators:"))
        #expect(!model.isBusy)
    }

    @Test func keepsStandardAndCanvasBroadcastsSeparate() async throws {
        let standard = try SimulatorFixtures.device(in: .standard)
        let preview = try SimulatorFixtures.device(in: .previews)
        let service = ServiceStub(devices: [standard, preview])
        let model = AppModel(simulatorService: service, selectionStore: SelectionStore(AppModel.allRunningID))
        await model.refreshDevices()
        #expect(model.targets.map(\.id) == [standard.id])
        #expect(model.runningDevices.map(\.id) == [standard.id])
        #expect(model.bootedCanvasDevices.map(\.id) == [preview.id])

        model.selectedDeviceID = AppModel.allPreviewsID
        #expect(model.targets.map(\.id) == [preview.id])
        #expect(!model.canShowSelectedDevice)
        await model.addLink("https://example.com")
        await model.sendAll()

        #expect(await service.deliveryIDs == [preview.id])
        #expect(model.items.isEmpty)
        guard case .success = model.status else {
            Issue.record("The Canvas broadcast should succeed.")
            return
        }
    }

    @Test func keepsEmptyCanvasBroadcastSelected() async throws {
        let standard = try SimulatorFixtures.device(in: .standard)
        let model = AppModel(
            simulatorService: ServiceStub(devices: [standard]),
            selectionStore: SelectionStore(AppModel.allPreviewsID)
        )
        await model.refreshDevices()

        #expect(model.selectedDeviceID == AppModel.allPreviewsID)
        #expect(model.targets.isEmpty)
        #expect(!model.canSend)
        #expect(!model.canShowSelectedDevice)
    }

    @Test func doesNotRetargetAnUnavailableCanvasSelection() async throws {
        let standard = try SimulatorFixtures.device(in: .standard)
        let preview = try SimulatorFixtures.device(in: .previews)
        let model = AppModel(
            simulatorService: ServiceStub(devices: [standard]),
            selectionStore: SelectionStore(preview.id)
        )
        await model.refreshDevices()
        await model.addLink("https://example.com")

        #expect(model.selectedDeviceID == preview.id)
        #expect(model.isCanvasDestinationSelected)
        #expect(model.targets.isEmpty)
        #expect(!model.canSend)
    }

    @Test func persistsStandardAndNamespacedCanvasSelections() async throws {
        let standard = try SimulatorFixtures.device(in: .standard)
        let preview = try SimulatorFixtures.device(in: .previews)
        let store = SelectionStore(standard.id)
        let model = AppModel(simulatorService: ServiceStub(devices: [standard, preview]), selectionStore: store)
        await model.refreshDevices()
        #expect(model.selectedDevice?.id == standard.id)

        model.selectedDeviceID = preview.id
        #expect(store.selectedSimulatorID == preview.id)
        #expect(preview.id == "previews:\(preview.udid)")
        #expect(!model.canShowSelectedDevice)
    }

    @Test func preservesSendFailuresAndAllowsRetry() async throws {
        let device = try SimulatorFixtures.device(in: .standard)
        let service = ServiceStub(devices: [device])
        let model = AppModel(simulatorService: service, selectionStore: SelectionStore(device.id))
        await model.refreshDevices()
        await model.addLink("https://example.com")
        await service.failSending(true)
        await model.sendAll()

        #expect(model.items.count == 1)
        #expect(model.failedCount == 1)
        #expect(model.canSend)
        guard case .failure = model.status else {
            Issue.record("The failed send must remain visible.")
            return
        }

        await service.failSending(false)
        await model.sendAll()
        #expect(model.items.isEmpty)
        guard case .success = model.status else {
            Issue.record("A successful retry must clear the prior failure.")
            return
        }
    }

    @Test func matchesShowButtonToDeviceStateAndApplication() async throws {
        let device = try SimulatorFixtures.device(in: .standard, isBooted: false)
        let service = ServiceStub(devices: [device])
        let model = AppModel(simulatorService: service, selectionStore: SelectionStore(device.id))
        await model.refreshDevices()
        #expect(model.showSimulatorTitle == String(localized: "simulators.runButton"))

        let running = try SimulatorFixtures.device(in: .standard)
        await service.replaceDevices([running])
        await model.refreshDevices()
        #expect(model.showSimulatorTitle == String(localized: "simulators.deviceHubButton"))
    }

    private final class SelectionStore: SimulatorSelectionStoring {
        var selectedSimulatorID: String

        init(_ selectedSimulatorID: String) {
            self.selectedSimulatorID = selectedSimulatorID
        }
    }

    private actor ServiceStub: SimulatorServicing {
        private var devices: [SimulatorDevice]
        private var listingFails = false
        private var openingFails = false
        private var sendingFails = false
        private(set) var deliveryIDs: [String] = []

        init(devices: [SimulatorDevice]) {
            self.devices = devices
        }

        func availableDevices() async throws -> [SimulatorDevice] {
            if listingFails {
                throw SimulatorServiceError.invalidResponse
            }

            return devices
        }

        func simulatorApplication() async throws -> SimulatorApplication {
            .deviceHub(URL(fileURLWithPath: "/Applications/Xcode_27.app/Contents/Applications/DeviceHub.app"))
        }

        func bootIfNeeded(_ device: SimulatorDevice) async throws {}

        func show(_ device: SimulatorDevice) async throws {
            if openingFails {
                throw SimulatorServiceError.commandFailed("Could not open Device Hub.")
            }
        }

        func send(_ item: QueueItem, to device: SimulatorDevice) async throws {
            if sendingFails {
                throw SimulatorServiceError.commandFailed("The link could not be opened.")
            }

            deliveryIDs.append(device.id)
        }

        func failListing(_ fails: Bool) {
            listingFails = fails
        }

        func failOpening(_ fails: Bool) {
            openingFails = fails
        }

        func failSending(_ fails: Bool) {
            sendingFails = fails
        }

        func replaceDevices(_ devices: [SimulatorDevice]) {
            self.devices = devices
        }
    }
}
