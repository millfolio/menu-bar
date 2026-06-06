import Foundation

/// Reachability + currently-served model of a local millrace server, polled over
/// its OpenAI-compatible `/v1/models` endpoint.
enum ServerStatus {
    case unknown, online, offline

    var title: String {
        switch self {
        case .unknown: return "Millrace: checking…"
        case .online: return "Millrace: online"
        case .offline: return "Millrace: offline"
        }
    }

    /// SF Symbol for the menu-bar icon (water-drop theme).
    var symbol: String {
        switch self {
        case .unknown: return "drop"
        case .online: return "drop.fill"
        case .offline: return "drop.triangle"
        }
    }
}

@MainActor
final class MillraceClient: ObservableObject {
    /// Default millrace server address (see mojo-backend: `pixi run serve`).
    let baseURL = "http://127.0.0.1:8000"

    @Published var status: ServerStatus = .unknown
    @Published var model: String? = nil

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
    }

    func refresh() {
        Task { await poll() }
    }

    /// GET /v1/models → {"data":[{"id":"…"}]}; first id is the served model.
    func poll() async {
        guard let url = URL(string: baseURL + "/v1/models") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                status = .offline
                model = nil
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["data"] as? [[String: Any]],
               let first = list.first,
               let id = first["id"] as? String {
                model = id
            }
            status = .online
        } catch {
            status = .offline
            model = nil
        }
    }
}
