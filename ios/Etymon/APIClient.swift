import Foundation

/// Talks to the Etymon backend. The simulator reaches the Mac at localhost; a device
/// needs the Mac's network address (set in Settings) and the server started with
/// `--host 0.0.0.0`.
struct APIClient {
    static let defaultBaseURL = "http://localhost:8000"
    static let baseURLKey = "apiBaseURL"

    var baseURL: URL
    var session: URLSession = .shared
    var cache: OfflineCache = .shared

    /// `-api <url>` launch argument (e.g. the Mac's address when run on a phone) is
    /// remembered, so later launches from the home screen use it too. Taken once, at
    /// launch: a server changed in Settings afterwards wins.
    private static let launchServer: Void = {
        if let url = LaunchOptions.value(after: "-api") {
            UserDefaults.standard.set(url, forKey: baseURLKey)
        }
    }()

    static func fromSettings() -> APIClient {
        _ = launchServer
        let stored = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
        return APIClient(baseURL: URL(string: stored) ?? URL(string: defaultBaseURL)!)
    }

    enum APIError: LocalizedError {
        case status(Int)
        /// The server can't be reached and this wasn't looked up before.
        case offline(URLError)
        var errorDescription: String? {
            switch self {
            case .status(let code): return "Server returned \(code)"
            case .offline: return "Offline, and not looked up before"
            }
        }
    }

    /// `wordLanguages`: a language for each word where it is known (spoken words), else nil.
    func scene(words: [String], lang: String?, maxCost: Double? = nil,
               wordLanguages: [String?] = []) async throws -> SceneResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("scene"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(
            SceneRequest(words: words.enumerated().map { i, word in
                .init(text: word, lang: i < wordLanguages.count ? wordLanguages[i] : nil)
            }, lang: lang,
                         maxCost: maxCost))
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

    func neighbors(of id: Int, children: Int = 16) async throws -> NeighborsResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("neighbors"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: String(id)),
                                 URLQueryItem(name: "children", value: String(children))]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10
        return try await send(request)
    }

    /// Lookups (GET) are kept on the device: when the server can't be reached, the last
    /// answer for the same question is used, so saved networks can be explored offline.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let cacheKey = request.httpMethod == "GET" ? request.url.map(OfflineCache.key) : nil
        let data: Data
        do {
            let (fresh, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw APIError.status(http.statusCode)
            }
            data = fresh
            if let cacheKey { cache.store(fresh, for: cacheKey) }
        } catch let error as URLError where error.code != .cancelled {
            guard let cacheKey, let cached = cache.data(for: cacheKey) else {
                throw APIError.offline(error)
            }
            data = cached
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
