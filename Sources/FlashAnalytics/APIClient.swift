import Foundation

final class APIClient {
    private let baseURL: URL
    private let defaultHeaders: [String: String]
    private let session: URLSession
    private let maxRetries: Int
    private let initialRetryDelayMs: UInt64

    init(
        baseURL: URL,
        defaultHeaders: [String: String],
        session: URLSession,
        maxRetries: Int,
        initialRetryDelayMs: UInt64
    ) {
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.session = session
        self.maxRetries = maxRetries
        self.initialRetryDelayMs = initialRetryDelayMs
    }

    func url(for path: String) -> URL {
        baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    func send(
        path: String,
        method: String = "POST",
        body: Any? = nil,
        queryItems: [URLQueryItem] = []
    ) async -> Data? {
        await send(path: path, method: method, body: body, queryItems: queryItems, attempt: 0)
    }

    private func send(
        path: String,
        method: String,
        body: Any?,
        queryItems: [URLQueryItem],
        attempt: Int
    ) async -> Data? {
        let baseURL = url(for: path)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }

        guard let url = components?.url else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = method
            defaultHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }

            if method != "GET", let body {
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return nil
            }

            switch httpResponse.statusCode {
            case 200, 202:
                return data.isEmpty ? nil : data
            case 401:
                return nil
            default:
                throw APIError.httpStatus(httpResponse.statusCode)
            }
        } catch {
            guard attempt < maxRetries else { return nil }
            let delayMs = initialRetryDelayMs * (1 << attempt)
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            return await send(
                path: path,
                method: method,
                body: body,
                queryItems: queryItems,
                attempt: attempt + 1
            )
        }
    }
}

private enum APIError: Error {
    case httpStatus(Int)
}
