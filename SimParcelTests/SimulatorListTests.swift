import Foundation
import Testing

struct SimulatorListTests {
    private let json = Data("""
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
          { "udid": "A", "name": "iPhone 17", "state": "Shutdown", "isAvailable": true }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-27-1": [
          { "udid": "B", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true },
          { "udid": "C", "name": "iPad Air", "state": "Booted", "isAvailable": true }
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-12-0": [
          { "udid": "D", "name": "Apple Watch", "state": "Shutdown", "isAvailable": true }
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-17-5": []
      }
    }
    """.utf8)

    @Test func parsesRuntimeIdentifiers() throws {
        let runtime = try #require(SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-1"))
        #expect(runtime.platform == "iOS")
        #expect(runtime.version == [27, 1])
        #expect(runtime.name == "iOS 27.1")

        #expect(SimulatorRuntime(identifier: "com.example.iOS-27") == nil)
        #expect(SimulatorRuntime(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-beta") == nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(SimulatorRuntime(platform: "iOS", version: [9, 0]) < SimulatorRuntime(platform: "iOS", version: [17, 5]))
        #expect(SimulatorRuntime(platform: "iOS", version: [27]) < SimulatorRuntime(platform: "iOS", version: [27, 1]))
    }

    @Test func keepsOnlyIOSDevices() throws {
        let devices = try SimulatorList.parse(json)
        #expect(Set(devices.map(\.id)) == ["A", "B", "C"])
        #expect(devices.first { $0.id == "C" }?.isBooted == true)
    }

    /// Keeps the device-specific runtime in the same picker section as the standard runtime.
    @Test func groupsDuoWithOtherDevicesOnTheSameIOSVersion() throws {
        let data = Data("""
        {
          "devices": {
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4": [
              { "udid": "93A8E793-7A27-490A-A522-4F75D8923882", "name": "iPhone Duo", "state": "Shutdown" }
            ],
            "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
              { "udid": "0CB83AED-016B-4D13-AE56-490E618E04C1", "name": "iPhone 18 Pro", "state": "Shutdown" }
            ]
          }
        }
        """.utf8)

        let groups = SimulatorList.shutdownGroups(in: try SimulatorList.parse(data))
        #expect(groups.map(\.runtime.name) == ["iOS 27.2"])
        #expect(Set(groups.flatMap(\.devices).map(\.name)) == ["iPhone 18 Pro", "iPhone Duo"])
    }

    @Test func rejectsNonJSONOutput() {
        #expect(throws: (any Error).self) {
            try SimulatorList.parse(Data("xcrun: warning\n{}".utf8))
        }
    }

    @Test func groupsNewestRuntimeFirstWithRunningDevicesFirst() throws {
        let groups = SimulatorList.grouped(try SimulatorList.parse(json))
        #expect(groups.map(\.runtime.name) == ["iOS 27.1", "iOS 26.5"])
        #expect(groups[0].devices.map(\.id) == ["C", "B"])
    }

    @Test func prefersRunningDevice() throws {
        let devices = try SimulatorList.parse(json)
        #expect(SimulatorList.preferredDevice(in: devices)?.id == "C")

        let shutDown = devices.filter { !$0.isBooted }
        #expect(SimulatorList.preferredDevice(in: shutDown)?.id == "B")
        #expect(SimulatorList.preferredDevice(in: []) == nil)
    }

    @Test func separatesRunningDevicesAcrossRuntimesWithoutDuplicates() throws {
        let parsed = try SimulatorList.parse(json)
        let devices = parsed + [SimulatorDevice(
            id: "E", name: "iPhone 15", runtime: SimulatorRuntime(platform: "iOS", version: [17, 5]),
            isBooted: true, dataPath: nil
        )]

        let running = SimulatorList.runningDevices(in: devices)
        let groups = SimulatorList.shutdownGroups(in: devices)
        #expect(running.map(\.id) == ["C", "E"])
        #expect(running.map(\.label) == ["iPad Air · iOS 27.1", "iPhone 15 · iOS 17.5"])
        #expect(groups.map(\.runtime.name) == ["iOS 27.1", "iOS 26.5"])
        #expect(groups.flatMap(\.devices).map(\.id) == ["B", "A"])
        let listedIDs = running.map(\.id) + groups.flatMap(\.devices).map(\.id)
        #expect(listedIDs.count == devices.count)
        #expect(Set(listedIDs) == Set(devices.map(\.id)))
    }

    @Test func handlesNoRunningAndAllRunningDevices() throws {
        let devices = try SimulatorList.parse(json)
        let shutdown = devices.filter { !$0.isBooted }
        #expect(SimulatorList.runningDevices(in: shutdown).isEmpty)
        #expect(SimulatorList.shutdownGroups(in: shutdown).flatMap(\.devices).count == shutdown.count)

        let running = devices.filter(\.isBooted)
        #expect(SimulatorList.runningDevices(in: running) == running)
        #expect(SimulatorList.shutdownGroups(in: running).isEmpty)
        #expect(SimulatorList.runningDevices(in: []).isEmpty)
        #expect(SimulatorList.shutdownGroups(in: []).isEmpty)
    }

    @Test func movesDeviceBetweenSectionsWhenItsStateChanges() throws {
        let running = try #require(SimulatorList.parse(json).first { $0.id == "C" })
        let shutdown = SimulatorDevice(
            id: running.id, name: running.name, runtime: running.runtime, isBooted: false, dataPath: running.dataPath
        )

        #expect(SimulatorList.runningDevices(in: [running]).map(\.id) == ["C"])
        #expect(SimulatorList.shutdownGroups(in: [running]).isEmpty)
        #expect(SimulatorList.runningDevices(in: [shutdown]).isEmpty)
        #expect(SimulatorList.shutdownGroups(in: [shutdown]).flatMap(\.devices).map(\.id) == ["C"])
    }
}
