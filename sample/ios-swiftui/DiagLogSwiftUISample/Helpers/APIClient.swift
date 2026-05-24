import Foundation

struct APIClient {
    func upload(fileURL: URL, to uploadURL: String, bearerToken: String) async throws -> String {
        guard let url = URL(string: uploadURL) else {
            throw URLError(.badURL)
        }

        let boundary = "AppDiagLogBoundary\(UInt64(Date().timeIntervalSince1970 * 1_000_000))"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let trimmedToken = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try Self.multipartBody(fileURL: fileURL, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
        return "HTTP \(status): \(preview)"
    }

    private static func multipartBody(fileURL: URL, boundary: String) throws -> Data {
        let fileData = try Data(contentsOf: fileURL)
        let fileName = sanitizedFileName(fileURL.lastPathComponent)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/zip\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func sanitizedFileName(_ name: String) -> String {
        String(name.map { character in
            switch character {
            case "\r", "\n", "\"":
                return "_"
            default:
                return character
            }
        })
    }
}
