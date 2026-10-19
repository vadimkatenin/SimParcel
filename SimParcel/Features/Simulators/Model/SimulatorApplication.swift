import Foundation

enum SimulatorApplication: Sendable {
    case simulator(URL)
    case deviceHub(URL)

    var showTitle: String {
        switch self {
        case .simulator: String(localized: "simulators.showButton")
        case .deviceHub: String(localized: "simulators.deviceHubButton")
        }
    }

    var showHelp: String {
        switch self {
        case .simulator: String(localized: "simulators.showHint")
        case .deviceHub: String(localized: "simulators.deviceHubHint")
        }
    }
}
