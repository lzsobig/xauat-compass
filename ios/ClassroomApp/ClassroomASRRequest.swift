import Foundation

enum ClassroomASRRequest {
    static func make(provider: CloudTranscriptionProvider, key: String, audioData: Data,
                     filename: String = "audio.wav", mimeType: String = "audio/wav") throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw NSError(domain: "CloudASR", code: 401,
                userInfo: [NSLocalizedDescriptionKey: "请填写首页所选服务对应的 API Key"])
        }
        guard let url = URL(string: provider.endpoint) else { throw URLError(.badURL) }
        let boundary = "Boundary-" + UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        let name = filename.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(provider.model)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }
}
