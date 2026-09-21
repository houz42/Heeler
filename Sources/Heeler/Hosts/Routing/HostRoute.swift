import Foundation

/// Per-route eligibility gate for automatic route selection (v2).
/// "Wi-Fi only" is a HINT gate: the current path's interface
/// classification says Wi-Fi or it does not, and classification is not
/// proof of which VPN is or is not active — the design contract forbids
/// inferring provider state from interface types. The dial itself
/// remains the real proof.
enum HostRouteEligibility: String, Codable, Hashable, Sendable {
    case anyNetwork
    case wifiOnly

    var title: String {
        switch self {
        case .anyNetwork: "Any network"
        case .wifiOnly: "Wi-Fi only"
        }
    }
}

/// Per-Host route selection (v2, design: "Route selection: Automatic /
/// Choose route manually"). Automatic dials the saved priority order
/// over eligible routes. Manual PINS one route — the pin is never
/// silently overridden, and it dials exactly its address even after the
/// Host's address list is edited; a stale pin is surfaced honestly with
/// a "Return to automatic" action, never reinterpreted.
enum HostRouteSelection: Equatable, Hashable, Sendable {
    case automatic
    case manual(address: String)

    var isAutomatic: Bool {
        self == .automatic
    }
}

extension HostRouteSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case manualAddress
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .automatic:
            var container = encoder.singleValueContainer()
            try container.encode("automatic")
        case .manual(let address):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(address, forKey: .manualAddress)
        }
    }

    init(from decoder: any Decoder) throws {
        if
            let container = try? decoder.container(keyedBy: CodingKeys.self),
            let address = try? container.decodeIfPresent(String.self, forKey: .manualAddress),
            !address.isEmpty
        {
            self = .manual(address: address)
            return
        }
        var container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard raw == "automatic" else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unknown route selection: \(raw)")
        }
        self = .automatic
    }
}
