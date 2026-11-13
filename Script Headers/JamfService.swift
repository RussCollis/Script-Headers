import Foundation
import Observation
import Security

/// A saved Jamf Pro server. The client secret is kept in the keychain under the instance's ID.
nonisolated struct JamfInstance: Identifiable, Hashable, Codable {
    var id = UUID()
    var name: String
    var serverURL: String
    var clientID: String

    /// The server address without any path, accepting "yourcompany.jamfcloud.com" as well as full console links.
    var server: URL? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host != nil else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return server?.host() ?? "New Jamf Instance"
    }
}

/// A script or computer extension attribute in Jamf Pro.
struct JamfItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable, Identifiable {
        case script = "Scripts"
        case extensionAttribute = "Extension Attributes"

        var id: String { rawValue }
        var scriptKind: ScriptKind { self == .script ? .script : .extensionAttribute }
        var noun: String { self == .script ? "script" : "extension attribute" }
    }

    let kind: Kind
    let jamfID: Int
    var name: String
    var category = ""
    /// Whether the script already has a standard header; checked after the list loads.
    var status: HeaderStatus = .unchecked

    var id: String { "\(kind.rawValue)-\(jamfID)" }
}

/// Whether a script in Jamf Pro already has an Info Headers (house format) header.
enum HeaderStatus: Hashable {
    case unchecked
    case noHeader
    case header(version: String?, updated: String?)
    /// An extension attribute whose input type isn't a script, so it can't have a header.
    case notScript
    case failed

    /// Reads the header from a script's contents.
    init(contents: String, name: String) {
        let language = ScriptLanguage.detect(shebang: contents.components(separatedBy: "\n").first, fileName: name)
        let parsed = HeaderParser.parse(ScriptSplit(text: contents, language: language).headerLines)
        if parsed.fields[.scriptName] != nil {
            self = .header(version: parsed.version, updated: parsed.fields[.updated])
        } else {
            self = .noHeader
        }
    }

    var hasHeader: Bool {
        if case .header = self { return true }
        return false
    }
}

/// Where a document was loaded from in Jamf Pro, so it can be pushed back.
struct JamfSource: Hashable {
    let instanceID: JamfInstance.ID
    let instanceName: String
    let item: JamfItem
}

/// A script or extension attribute read from Jamf Pro, with the details useful for its header.
struct JamfRecord {
    var item: JamfItem
    var contents: String
    /// Labels set for parameters 4–11 in the script's settings.
    var parameterLabels: [Int: String] = [:]
    var notes = ""
    var dataType: EADataType?
}

enum JamfError: LocalizedError {
    case invalidServer
    case http(Int, String)
    case notScript
    case notVerified
    case notConnected(String)

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Enter the Jamf Pro server address, e.g. https://yourcompany.jamfcloud.com."
        case .http(401, _):
            "Jamf Pro rejected the client ID or secret."
        case .http(403, _):
            "The API client doesn't have permission. Give its API role Read and Update Scripts, and Read and Update Computer Extension Attributes."
        case .http(404, _):
            "Jamf Pro couldn't find that item. It may have been deleted."
        case .http(let status, let message):
            "Jamf Pro returned an error (\(status))\(message.isEmpty ? "." : ": \(message)")"
        case .notScript:
            "This extension attribute doesn't use a script (its Input Type is a text field, pop-up menu or directory service attribute)."
        case .notVerified:
            "Jamf Pro accepted the update, but the script read back afterwards doesn't match. Check it in Jamf Pro."
        case .notConnected(let name):
            "Connect to \(name) with Load from Jamf Pro first."
        }
    }
}

/// Talks to Jamf Pro with an API client (Settings › API Roles and Clients).
/// Only reads scripts and extension attributes and updates their script contents – nothing else is changed.
final class JamfClient {
    let server: URL
    let instanceID: JamfInstance.ID
    private let clientID: String
    private let clientSecret: String
    private var token: String?
    private var tokenExpiry = Date.distantPast
    private let session = URLSession(configuration: .ephemeral)

    init(server: URL, instanceID: JamfInstance.ID, clientID: String, clientSecret: String) {
        self.server = server
        self.instanceID = instanceID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    // MARK: - Scripts (Jamf Pro API)

    func scripts() async throws -> [JamfItem] {
        var items: [JamfItem] = []
        var page = 0
        while true {
            let json = try await object("api/v1/scripts", query: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: "200"),
                URLQueryItem(name: "sort", value: "name:asc"),
            ])
            let results = json["results"] as? [[String: Any]] ?? []
            items += results.compactMap { result in
                guard let id = Self.int(result["id"]) else { return nil }
                let name = result["name"] as? String ?? "Script \(id)"
                var item = JamfItem(kind: .script, jamfID: id, name: name, category: result["categoryName"] as? String ?? "")
                // The list includes each script's contents, so its header can be checked straight away.
                if let contents = result["scriptContents"] as? String {
                    item.status = HeaderStatus(contents: contents, name: name)
                }
                return item
            }
            let total = Self.int(json["totalCount"]) ?? items.count
            if results.isEmpty || items.count >= total { return items }
            page += 1
        }
    }

    func script(_ item: JamfItem) async throws -> JamfRecord {
        let json = try await object("api/v1/scripts/\(item.jamfID)")
        var labels: [Int: String] = [:]
        for number in 4...11 {
            if let label = (json["parameter\(number)"] as? String)?.trimmed, !label.isEmpty { labels[number] = label }
        }
        var item = item
        item.name = json["name"] as? String ?? item.name
        let notes = [json["info"] as? String, json["notes"] as? String]
            .compactMap { $0?.trimmed }.first { !$0.isEmpty } ?? ""
        return JamfRecord(item: item, contents: json["scriptContents"] as? String ?? "",
                          parameterLabels: labels, notes: notes)
    }

    /// Replaces the script's contents, keeping every other setting as Jamf Pro has it.
    func updateScript(_ item: JamfItem, contents: String) async throws {
        var json = try await object("api/v1/scripts/\(item.jamfID)")
        json["scriptContents"] = contents
        let body = try JSONSerialization.data(withJSONObject: json)
        _ = try await send("PUT", "api/v1/scripts/\(item.jamfID)", body: body, contentType: "application/json")
        let check = try await script(item)
        guard normalised(check.contents) == normalised(contents) else { throw JamfError.notVerified }
    }

    // MARK: - Extension attributes (Classic API, which every Jamf Pro version supports)

    func extensionAttributes() async throws -> [JamfItem] {
        let json = try await object("JSSResource/computerextensionattributes")
        let list = json["computer_extension_attributes"] as? [[String: Any]] ?? []
        return list.compactMap { entry in
            guard let id = Self.int(entry["id"]) else { return nil }
            return JamfItem(kind: .extensionAttribute, jamfID: id, name: entry["name"] as? String ?? "Extension Attribute \(id)")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func extensionAttribute(_ item: JamfItem) async throws -> JamfRecord {
        let json = try await object("JSSResource/computerextensionattributes/id/\(item.jamfID)")
        let ea = json["computer_extension_attribute"] as? [String: Any] ?? [:]
        let input = ea["input_type"] as? [String: Any] ?? [:]
        guard (input["type"] as? String)?.lowercased() == "script" else { throw JamfError.notScript }
        var item = item
        item.name = ea["name"] as? String ?? item.name
        let dataType = (ea["data_type"] as? String).flatMap { type in
            EADataType.allCases.first { $0.rawValue.lowercased() == type.lowercased() }
        }
        return JamfRecord(item: item, contents: input["script"] as? String ?? "",
                          notes: (ea["description"] as? String)?.trimmed ?? "", dataType: dataType)
    }

    /// Replaces only the extension attribute's script.
    func updateExtensionAttribute(_ item: JamfItem, contents: String) async throws {
        let xml = """
        <computer_extension_attribute><input_type><type>script</type><platform>Mac</platform>\
        <script>\(xmlEscaped(contents))</script></input_type></computer_extension_attribute>
        """
        _ = try await send("PUT", "JSSResource/computerextensionattributes/id/\(item.jamfID)",
                           body: Data(xml.utf8), contentType: "application/xml")
        let check = try await extensionAttribute(item)
        guard normalised(check.contents) == normalised(contents) else { throw JamfError.notVerified }
    }

    // MARK: - Requests

    private func object(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        let data = try await send("GET", path, query: query)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
                      contentType: String? = nil) async throws -> Data {
        var url = server.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        return data
    }

    /// Fetches an OAuth token with the client credentials, reusing it until shortly before it expires.
    func accessToken() async throws -> String {
        if let token, tokenExpiry > .now.addingTimeInterval(30) { return token }

        var request = URLRequest(url: server.appending(path: "api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = ["grant_type": "client_credentials", "client_id": clientID, "client_secret": clientSecret]
        request.httpBody = Data(form.map { "\($0.key)=\(formEncoded($0.value))" }.joined(separator: "&").utf8)

        let (data, response) = try await session.data(for: request)
        try check(response, data)
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let accessToken = json["access_token"] as? String else { throw JamfError.http(401, "") }
        token = accessToken
        tokenExpiry = .now.addingTimeInterval((json["expires_in"] as? Double) ?? 60)
        return accessToken
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        // Jamf error bodies are often HTML pages, so keep just a short readable snippet.
        let message = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmed
        throw JamfError.http(http.statusCode, String(message.prefix(200)))
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// Secrets can contain "+", "&" or "=", which must be escaped in a form body.
    private func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func xmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Jamf may store line endings or trailing whitespace differently from what was sent.
    private func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Saved Jamf Pro instances, the current connection and the items shown in the Jamf browser.
@Observable
final class JamfModel {
    var instances: [JamfInstance] {
        didSet { saveInstances() }
    }
    var selectedID: JamfInstance.ID? {
        didSet {
            UserDefaults.standard.set(selectedID?.uuidString, forKey: Keys.selected)
            if client?.instanceID != selectedID { disconnect() }
            loadSavedSecret()
        }
    }
    var clientSecret = ""
    var scripts: [JamfItem] = []
    var extensionAttributes: [JamfItem] = []
    var isConnecting = false
    var errorMessage: String?
    private(set) var client: JamfClient?
    /// Progress of the background header check, e.g. (12, 80); nil when it isn't running.
    private(set) var checkProgress: (done: Int, total: Int)?
    private var checkTask: Task<Void, Never>?

    private enum Keys {
        static let instances = "jamfInstances"
        static let selected = "jamfSelectedInstance"
        static let pushes = "jamfPushes"
    }

    /// When each item was last updated from this Mac, keyed by instance ID then item ID.
    private var pushes: [String: [String: Date]] {
        get { UserDefaults.standard.dictionary(forKey: Keys.pushes) as? [String: [String: Date]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Keys.pushes) }
    }

    /// When an item was last updated in Jamf Pro with Info Headers on this Mac.
    func lastPushed(_ item: JamfItem) -> Date? {
        guard let instance = client?.instanceID.uuidString else { return nil }
        return pushes[instance]?[item.id]
    }

    init() {
        let saved = UserDefaults.standard.data(forKey: Keys.instances)
            .flatMap { try? JSONDecoder().decode([JamfInstance].self, from: $0) } ?? []
        instances = saved.isEmpty ? [JamfInstance(name: "", serverURL: "", clientID: "")] : saved
        let selected = UserDefaults.standard.string(forKey: Keys.selected).flatMap(UUID.init(uuidString:))
        selectedID = instances.contains { $0.id == selected } ? selected : instances.first?.id
        loadSavedSecret()
    }

    var selectedInstance: JamfInstance? { instances.first { $0.id == selectedID } }
    var connectedInstance: JamfInstance? { instances.first { $0.id == client?.instanceID } }
    var isConnected: Bool { client != nil }
    var host: String { client?.server.host() ?? "" }

    var instanceName: String {
        get { selectedInstance?.name ?? "" }
        set { updateSelected { $0.name = newValue } }
    }
    var serverURL: String {
        get { selectedInstance?.serverURL ?? "" }
        set { updateSelected { $0.serverURL = newValue } }
    }
    var clientID: String {
        get { selectedInstance?.clientID ?? "" }
        set { updateSelected { $0.clientID = newValue } }
    }

    var canConnect: Bool {
        selectedInstance?.server != nil && !clientID.trimmed.isEmpty && !clientSecret.isEmpty && !isConnecting
    }

    func addInstance() {
        let instance = JamfInstance(name: "", serverURL: "", clientID: "")
        instances.append(instance)
        selectedID = instance.id
    }

    /// Removes the selected instance and its saved secret. The last instance can't be removed.
    func removeSelectedInstance() {
        guard instances.count > 1, let id = selectedID else { return }
        Keychain.save("", for: id.uuidString)
        instances.removeAll { $0.id == id }
        selectedID = instances.first?.id
    }

    func loadSavedSecret() {
        clientSecret = selectedID.flatMap { Keychain.read($0.uuidString) } ?? ""
    }

    /// Signs in and loads the scripts and extension attributes.
    func connect() async {
        guard let instance = selectedInstance, let server = instance.server else {
            errorMessage = JamfError.invalidServer.localizedDescription
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        let client = JamfClient(server: server, instanceID: instance.id, clientID: instance.clientID.trimmed,
                                clientSecret: clientSecret)
        do {
            _ = try await client.accessToken()
            Keychain.save(clientSecret, for: instance.id.uuidString)
            self.client = client
            try await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async throws {
        guard let client else { return }
        scripts = try await client.scripts()
        // A role without extension attribute access can still work with scripts.
        do {
            extensionAttributes = try await client.extensionAttributes()
        } catch {
            extensionAttributes = []
            errorMessage = "Extension attributes couldn't be listed: \(error.localizedDescription)"
        }
        checkHeaders()
    }

    /// Reads, in the background, each item whose header wasn't in the list. The Classic API lists
    /// extension attributes without their scripts, so each one is fetched.
    private func checkHeaders() {
        checkTask?.cancel()
        let pending = (scripts + extensionAttributes).filter { $0.status == .unchecked }
        guard let client, !pending.isEmpty else {
            checkProgress = nil
            return
        }
        checkProgress = (0, pending.count)
        checkTask = Task {
            // A few at a time keeps large instances quick without flooding the server.
            for batch in stride(from: 0, to: pending.count, by: 6).map({ Array(pending[$0..<min($0 + 6, pending.count)]) }) {
                // Child tasks only fetch; the header is read back on the main actor.
                await withTaskGroup(of: (JamfItem, Result<String, JamfError>?).self) { group in
                    for item in batch {
                        group.addTask {
                            do {
                                let record = item.kind == .script ? try await client.script(item)
                                                                  : try await client.extensionAttribute(item)
                                return (item, .success(record.contents))
                            } catch let error as JamfError {
                                return (item, .failure(error))
                            } catch {
                                return (item, nil)
                            }
                        }
                    }
                    for await (item, result) in group {
                        switch result {
                        case .success(let contents): setStatus(HeaderStatus(contents: contents, name: item.name), for: item)
                        case .failure(.notScript): setStatus(.notScript, for: item)
                        default: setStatus(.failed, for: item)
                        }
                    }
                }
                guard !Task.isCancelled, let progress = checkProgress else { return }
                checkProgress = (min(progress.done + batch.count, progress.total), progress.total)
            }
            checkProgress = nil
        }
    }

    private func setStatus(_ status: HeaderStatus, for item: JamfItem) {
        switch item.kind {
        case .script:
            if let index = scripts.firstIndex(where: { $0.id == item.id }) { scripts[index].status = status }
        case .extensionAttribute:
            if let index = extensionAttributes.firstIndex(where: { $0.id == item.id }) { extensionAttributes[index].status = status }
        }
    }

    func disconnect() {
        checkTask?.cancel()
        checkProgress = nil
        client = nil
        scripts = []
        extensionAttributes = []
    }

    func load(_ item: JamfItem) async throws -> JamfRecord {
        guard let client else { throw JamfError.notConnected(selectedInstance?.displayName ?? "Jamf Pro") }
        return item.kind == .script ? try await client.script(item) : try await client.extensionAttribute(item)
    }

    /// Writes the new contents back to the item the document came from.
    func push(_ contents: String, to source: JamfSource) async throws {
        guard let client, client.instanceID == source.instanceID else {
            throw JamfError.notConnected(source.instanceName)
        }
        switch source.item.kind {
        case .script: try await client.updateScript(source.item, contents: contents)
        case .extensionAttribute: try await client.updateExtensionAttribute(source.item, contents: contents)
        }
        pushes[source.instanceID.uuidString, default: [:]][source.item.id] = .now
        setStatus(HeaderStatus(contents: contents, name: source.item.name), for: source.item)
    }

    private func updateSelected(_ change: (inout JamfInstance) -> Void) {
        guard let index = instances.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&instances[index])
    }

    private func saveInstances() {
        if let data = try? JSONEncoder().encode(instances) {
            UserDefaults.standard.set(data, forKey: Keys.instances)
        }
    }
}

/// Stores the API client secret in the login keychain rather than in preferences.
enum Keychain {
    private static let service = "Info Headers – Jamf Pro"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
