import Foundation

protocol SimulatorServicing: Sendable {
    func availableDevices() async throws -> [SimulatorDevice]
    func simulatorApplication() async throws -> SimulatorApplication
    func bootIfNeeded(_ device: SimulatorDevice) async throws
    func show(_ device: SimulatorDevice) async throws
    func send(_ item: QueueItem, to device: SimulatorDevice) async throws
}

protocol SimulatorCommandRunning: Sendable {
    func output(_ executable: String, _ arguments: [String]) async throws -> Data
}
