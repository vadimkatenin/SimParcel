import Foundation

struct SimulatorRuntime: Hashable, Comparable, Sendable {
    let platform: String
    let version: [Int]

    init(platform: String, version: [Int]) {
        self.platform = platform
        self.version = version
    }

    /// Parses runtime identifiers such as `com.apple.CoreSimulator.SimRuntime.iOS-27-1`.
    init?(identifier: String) {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard identifier.hasPrefix(prefix) else {
            return nil
        }

        let components = identifier.dropFirst(prefix.count).split(separator: "-")
        let version = components.dropFirst().compactMap { Int($0) }
        guard let platform = components.first, version.count == components.count - 1 else {
            return nil
        }

        self.init(platform: String(platform), version: version)
    }

    var name: String {
        version.isEmpty ? platform : "\(platform) \(version.map(String.init).joined(separator: "."))"
    }

    static func < (lhs: SimulatorRuntime, rhs: SimulatorRuntime) -> Bool {
        if lhs.platform != rhs.platform {
            return lhs.platform < rhs.platform
        }

        return lhs.version.lexicographicallyPrecedes(rhs.version)
    }
}

struct SimulatorDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let runtime: SimulatorRuntime
    let isBooted: Bool
    let dataPath: String?

    var label: String {
        "\(name) · \(runtime.name)"
    }

    var symbolName: String {
        name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone"
    }
}

struct SimulatorRuntimeGroup: Identifiable, Hashable, Sendable {
    let runtime: SimulatorRuntime
    let devices: [SimulatorDevice]

    var id: SimulatorRuntime {
        runtime
    }
}

enum SimulatorList {
    /// Platforms whose simulators have a Photos library that `simctl addmedia` can write to.
    static let supportedPlatforms: Set<String> = ["iOS"]

    /// Decodes the output of `simctl list devices available --json`.
    static func parse(_ data: Data) throws -> [SimulatorDevice] {
        let response = try JSONDecoder().decode(Response.self, from: data)

        return response.devices.flatMap { identifier, devices -> [SimulatorDevice] in
            guard let runtime = SimulatorRuntime(identifier: identifier),
                  supportedPlatforms.contains(runtime.platform) else {
                return []
            }

            return devices.map { device in
                SimulatorDevice(
                    id: device.udid,
                    name: device.name,
                    runtime: runtime,
                    isBooted: device.state == "Booted",
                    dataPath: device.dataPath
                )
            }
        }
    }

    /// Groups devices by runtime, newest runtime first. Running devices come first within a group.
    static func grouped(_ devices: [SimulatorDevice]) -> [SimulatorRuntimeGroup] {
        Dictionary(grouping: devices, by: \.runtime)
            .map { runtime, devices in
                SimulatorRuntimeGroup(
                    runtime: runtime,
                    devices: devices.sorted {
                        if $0.isBooted != $1.isBooted {
                            return $0.isBooted
                        }

                        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted { $0.runtime > $1.runtime }
    }

    /// Running devices across all runtimes, newest runtime first.
    static func runningDevices(in devices: [SimulatorDevice]) -> [SimulatorDevice] {
        grouped(devices).flatMap(\.devices).filter(\.isBooted)
    }

    /// The remaining picker sections exclude devices already shown under Running.
    static func shutdownGroups(in devices: [SimulatorDevice]) -> [SimulatorRuntimeGroup] {
        grouped(devices.filter { !$0.isBooted })
    }

    /// The device to select when nothing valid is selected: a running one, otherwise one from the newest runtime.
    static func preferredDevice(in devices: [SimulatorDevice]) -> SimulatorDevice? {
        let groups = grouped(devices)
        return groups.lazy.flatMap(\.devices).first(where: \.isBooted) ?? groups.first?.devices.first
    }

    private struct Response: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let dataPath: String?
    }
}
