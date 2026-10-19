import Foundation

enum SimulatorFixtures {
    static func response(for deviceSet: SimulatorDeviceSet) throws -> Data {
        let name = deviceSet == .standard ? "standard-devices" : "canvas-devices"
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        return try Data(contentsOf: folder.appendingPathComponent(name).appendingPathExtension("json"))
    }

    static func device(in deviceSet: SimulatorDeviceSet, isBooted: Bool = true) throws -> SimulatorDevice {
        let devices = try SimulatorList.parse(response(for: deviceSet), deviceSet: deviceSet)
        guard let device = devices.first else {
            throw SimulatorServiceError.invalidResponse
        }

        return SimulatorDevice(
            id: device.udid,
            name: device.name,
            runtime: device.runtime,
            isBooted: isBooted,
            dataPath: device.dataPath,
            deviceSet: deviceSet
        )
    }
}
