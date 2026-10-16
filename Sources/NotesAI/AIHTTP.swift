import Foundation
import NotesCore

enum AIHTTP {
    static func request(_ path: String, config: AIConfig, consent: HostConsent, headers: [(String, String)],
                        reserved: Set<String>, body: some Encodable) throws -> URLRequest {
        guard config.isLoopback || consent.isGranted(config.host) else {
            throw AIError.consentRequired(host: config.host)
        }
        var base = config.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var request = URLRequest(url: URL(string: base + "/" + path)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        for header in config.extraHeaders where !reserved.contains(header.name.lowercased()) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func httpError(_ response: URLResponse, body: () async throws -> Data) async throws -> AIError? {
        guard let http = response as? HTTPURLResponse else { return .badResponse }
        if (200..<300).contains(http.statusCode) { return nil }
        if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
        let message = (try? JSONDecoder().decode(ErrorBody.self, from: await body()))?.error.message
        return .http(status: http.statusCode, message: message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
    }

    static func map(_ error: Error) -> Error {
        if error is AIError || error is CancellationError { return error }
        if let error = error as? URLError {
            return error.code == .cancelled ? CancellationError() : AIError.unreachable
        }
        return AIError.badResponse
    }
}

private struct ErrorBody: Decodable {
    struct Detail: Decodable { let message: String? }
    let error: Detail
}

extension Data {
    init(collecting bytes: URLSession.AsyncBytes) async throws {
        self.init()
        for try await byte in bytes { append(byte) }
    }
}
