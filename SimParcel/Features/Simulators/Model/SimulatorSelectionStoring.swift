import Foundation

@MainActor
protocol SimulatorSelectionStoring: AnyObject {
    var selectedSimulatorID: String { get set }
}

extension UserDefaults: SimulatorSelectionStoring {
    var selectedSimulatorID: String {
        get {
            string(forKey: "selectedSimulatorID") ?? ""
        }
        set {
            set(newValue, forKey: "selectedSimulatorID")
        }
    }
}
