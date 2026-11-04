import Foundation

/// Talks to the Etymon backend. The simulator reaches the Mac at localhost; a device
/// needs the Mac's network address (set in Settings) and the server started with
/// `--host 0.0.0.0`.
struct APIClient {
    static let defaultBaseURL = "http://localhost:8000"
    static let baseURLKey = "apiBaseURL"

    var baseURL: URL
    var session: URLSession = .shared

    static func fromSettings() -> APIClient {
        let stored = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
        return APIClient(baseURL: URL(string: stored) ?? URL(string: defaultBaseURL)!)
    }

    enum APIError: LocalizedError {
        case status(Int)
        var errorDescription: String? {
            switch self {
            case .status(let code): return "Server returned \(code)"
            }
        }
    }

    func scene(words: [String], lang: String?) async throws -> SceneResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("scene"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(
            SceneRequest(words: words.map { .init(text: $0, lang: nil) }, lang: lang))
        return try await send(request)
    }

    func word(_ text: String, lang: String?) async throws -> WordResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("word"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "text", value: text)]
            + (lang.map { [URLQueryItem(name: "lang", value: $0)] } ?? [])
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.status(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
