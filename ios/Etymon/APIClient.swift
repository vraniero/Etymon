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
    /// The dictionary on the phone, answering instead of a server (set by `fromSettings`
    /// when there is one; a client made for a given server never uses it).
    var local: LocalBackend? = nil

    /// `-api <url>` launch argument (e.g. the Mac's address when run on a phone) is
    /// remembered, so later launches from the home screen use it too. Taken once, at
    /// launch: a server changed in Settings afterwards wins.
    private static let launchServer: Void = {
        if let url = LaunchOptions.value(after: "-api") {
            UserDefaults.standard.set(url, forKey: baseURLKey)
        }
    }()

    /// The dictionary is on this phone (LocalBackend): questions are answered here, with
    /// no server. A server given at launch (`-api`, as the UI tests do) still wins.
    static var isLocal: Bool {
        LocalBackend.shared != nil && LaunchOptions.value(after: "-api") == nil
    }

    static func fromSettings() -> APIClient {
        _ = launchServer
        let stored = UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL
        return APIClient(baseURL: URL(string: stored) ?? URL(string: defaultBaseURL)!,
                         local: isLocal ? LocalBackend.shared : nil)
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

    /// Root Chain: the app's next word after `word`; 404 when it has none left.
    func chainReply(after word: String, lang: String?, used: [String], avoidRoot: Int?,
                    level: String, in language: String? = nil) async throws -> ChainReply {
        var request = URLRequest(url: baseURL.appendingPathComponent("chain/reply"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(ChainReplyRequest(
            word: .init(text: word, lang: lang), used: used, avoidRoot: avoidRoot, level: level,
            lang: language))
        return try await send(request)
    }

    // MARK: games

    /// Root Chain's opening word in a language.
    func chainStart(lang: String) async throws -> ChainStart {
        try await get("chain/start", ["lang": lang])
    }

    func impostor(lang: String?) async throws -> ImpostorPuzzle {
        try await get("games/impostor", ["lang": lang, "seed": Self.fresh])
    }

    func gameRoot(lang: String?) async throws -> GameRoot {
        try await get("games/root", ["lang": lang, "seed": Self.fresh])
    }

    func birthplace(lang: String?) async throws -> BirthplacePuzzle {
        try await get("games/birthplace", ["lang": lang, "seed": Self.fresh])
    }

    /// Which of the words descend from the root.
    func check(root: Int, words: [String], lang: String?) async throws -> GameCheck {
        var request = URLRequest(url: baseURL.appendingPathComponent("games/check"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(GameCheckRequest(
            root: root, words: words.map { .init(text: $0, lang: lang) }))
        return try await send(request)
    }

    /// A seed per puzzle: a new one each time, and no two cached answers alike.
    private static var fresh: String? { String(Int.random(in: 0..<1_000_000_000)) }

    private func get<T: Decodable>(_ path: String, _ query: [String: String?]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30  // a language's first puzzle reads its common words
        return try await send(request)
    }

    /// Lookups (GET) are kept on the device: when the server can't be reached, the last
    /// answer for the same question is used, so saved networks can be explored offline.
    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        if let local {
            return try JSONDecoder().decode(T.self, from: try await answer(request, with: local))
        }
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

    /// The request answered on the phone, as the server would.
    private func answer(_ request: URLRequest, with local: LocalBackend) async throws -> Data {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.status(400)
        }
        var path = components.path
        if path.hasPrefix(baseURL.path) { path.removeFirst(baseURL.path.count) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = Dictionary((components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { a, _ in a })
        do {
            return try await local.handle(method: request.httpMethod ?? "GET", path: path,
                                          query: query, body: request.httpBody)
        } catch let failure as LocalBackend.Failure {
            throw APIError.status(failure.status)
        }
    }
}
