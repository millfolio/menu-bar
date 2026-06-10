import Foundation

/// Reachability + version + currently-served model of a local millrace server,
/// polled over its `/v1/version` endpoint.
public enum ServerStatus: Equatable {
    case unknown, online, offline

    public var title: String {
        switch self {
        case .unknown: return "Millrace: checking…"
        case .online: return "Millrace: running"
        case .offline: return "Millrace: not running"
        }
    }

    /// SF Symbol for the menu-bar icon (water-drop theme).
    public var symbol: String {
        switch self {
        case .unknown: return "drop"
        case .online: return "drop.fill"
        case .offline: return "drop.triangle"
        }
    }
}

@MainActor
public final class MillraceClient: ObservableObject {
    /// Default millrace server address (see inference-server: `pixi run serve`).
    public let baseURL = "http://127.0.0.1:8000"

    @Published public var status: ServerStatus = .unknown
    @Published public var version: String? = nil
    @Published public var model: String? = nil

    private var timer: Timer?

    public init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    public func refresh() {
        Task { await poll() }
    }

    /// GET /v1/version → {"engine":"millrace","version":"…","model":"…"}.
    /// Drives the "is the engine installed/running?" state and shows its version.
    public func poll() async {
        guard let url = URL(string: baseURL + "/v1/version") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status = .offline
                version = nil
                model = nil
                return
            }
            version = json["version"] as? String
            model = json["model"] as? String
            status = .online
        } catch {
            status = .offline
            version = nil
            model = nil
        }
    }
}
