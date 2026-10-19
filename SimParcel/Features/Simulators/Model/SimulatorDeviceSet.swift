import Foundation

enum SimulatorDeviceSet: String, Hashable, Sendable {
    case standard
    case previews

    func arguments(for command: [String]) -> [String] {
        (self == .previews ? ["--set", "previews"] : []) + command
    }
}
