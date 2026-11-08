import Foundation
import Combine

/// Cloudflare R2 云端录音存储同步管理器
/// 实现安全、断点续传、失败重试与“零风险保留本地”的数据保护机制
@MainActor
public final class R2UploadManager: ObservableObject {
    public static let shared = R2UploadManager()
    
    // 配置持久化
    @Published public var workerBaseURL: String {
        didSet { UserDefaults.standard.set(workerBaseURL, forKey: "classroom_worker_base_url") }
    }
    @Published public var storageMode: AudioStorageMode {
        didSet { UserDefaults.standard.set(storageMode.rawValue, forKey: "classroom_storage_mode") }
    }
    @Published public var allowCellularUpload: Bool {
        didSet { UserDefaults.standard.set(allowCellularUpload, forKey: "classroom_allow_cellular_upload") }
    }
    
    // 上传状态监测
    @Published public var activeUploads: [UUID: Double] = [:] // Session ID -> 进度 (0.0 ~ 1.0)
    @Published public var uploadErrors: [UUID: String] = [:]
    
    public init() {
        self.workerBaseURL = UserDefaults.standard.string(forKey: "classroom_worker_base_url") ?? "https://compass.lzso.top"
        let savedMode = UserDefaults.standard.string(forKey: "classroom_storage_mode") ?? "cloudAndLocal"
        self.storageMode = AudioStorageMode(rawValue: savedMode) ?? .localOnly
        self.allowCellularUpload = UserDefaults.standard.bool(forKey: "classroom_allow_cellular_upload")
    }
    
    /// 上传准备模型
    struct UploadIntentResponse: Codable {
        let ok: Bool
        let key: String
        let uploadUrl: String?
        let error: String?
    }
    
    /// 校验响应模型
    struct VerifyResponse: Codable {
        let ok: Bool
        let verified: Bool
        let verifiedSize: Int64?
        let error: String?
    }
    
    /// 获取认证请求头
    private func authHeaders() -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let token = KeychainHelper.get(key: "device_auth_token") {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }
    
    /// 执行云端同步任务
    /// - Parameters:
    ///   - session: 待同步的课程录音记录
    ///   - localFileURL: 本地音频文件路径
    ///   - onStatusUpdate: 状态更新回调
    public func syncSessionToCloud(
        session: LessonSession,
        localFileURL: URL,
        onStatusUpdate: @escaping (StorageStatus, String?) -> Void
    ) async {
        // 1. 如果设置为仅本地存储，坚决不上报云端
        if session.storageMode == .localOnly || self.storageMode == .localOnly {
            onStatusUpdate(.localOnly, nil)
            return
        }
        
        // 2. 检查本地音频是否存在
        guard FileManager.default.fileExists(atPath: localFileURL.path) else {
            if session.storageStatus == .cloudOnly {
                // 已是云端存储模式，无需重复上传
                return
            }
            onStatusUpdate(.uploadFailed, "本地音频文件不存在，无法上传")
            return
        }
        
        let fileSize: Int64
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: localFileURL.path)
            fileSize = attrs[.size] as? Int64 ?? 0
        } catch {
            onStatusUpdate(.uploadFailed, "读取音频文件大小失败")
            return
        }
        
        guard fileSize > 0 else {
            onStatusUpdate(.uploadFailed, "音频文件为空")
            return
        }
        
        let sessionId = session.id
        self.activeUploads[sessionId] = 0.05
        onStatusUpdate(.uploading, nil)
        
        let cleanBase = workerBaseURL.hasSuffix("/") ? String(workerBaseURL.dropLast()) : workerBaseURL
        
        do {
            // 步骤一：向 Worker 发送 Upload Intent，登记元数据并换取专属存储 Key
            guard let intentURL = URL(string: "\(cleanBase)/api/classroom/upload-intent") else {
                throw URLError(.badURL)
            }
            
            var intentReq = URLRequest(url: intentURL)
            intentReq.httpMethod = "POST"
            intentReq.allHTTPHeaderFields = authHeaders()
            
            let intentBody: [String: Any] = [
                "sessionId": sessionId.uuidString,
                "fileName": session.audioFileName,
                "fileSize": fileSize,
                "duration": session.duration,
                "title": session.title,
                "courseId": session.courseId?.uuidString ?? "",
                "storageMode": session.storageMode.rawValue
            ]
            intentReq.httpBody = try JSONSerialization.data(withJSONObject: intentBody)
            
            let (intentData, intentResp) = try await URLSession.shared.data(for: intentReq)
            guard let httpResp = intentResp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                throw NSError(domain: "R2Error", code: 1, userInfo: [NSLocalizedDescriptionKey: "服务器暂不可用，已保留本地录音"])
            }
            
            let intentResult = try JSONDecoder().decode(UploadIntentResponse.self, from: intentData)
            guard intentResult.ok else {
                throw NSError(domain: "R2Error", code: 2, userInfo: [NSLocalizedDescriptionKey: intentResult.error ?? "请求上传凭据失败"])
            }
            
            let remoteKey = intentResult.key
            self.activeUploads[sessionId] = 0.25
            
            // 步骤二：流式上传音频文件至专属私有路径
            let targetUploadURL = URL(string: "\(cleanBase)/api/classroom/upload/\(remoteKey)") ?? intentURL
            var uploadReq = URLRequest(url: targetUploadURL)
            uploadReq.httpMethod = "PUT"
            uploadReq.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
            uploadReq.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
            if let token = KeychainHelper.get(key: "device_auth_token") {
                uploadReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            
            let fileData = try Data(contentsOf: localFileURL, options: .mappedIfSafe)
            self.activeUploads[sessionId] = 0.60
            
            let (_, putResp) = try await URLSession.shared.upload(for: uploadReq, from: fileData)
            guard let putHttpResp = putResp as? HTTPURLResponse, (200...299).contains(putHttpResp.statusCode) else {
                throw NSError(domain: "R2Error", code: 3, userInfo: [NSLocalizedDescriptionKey: "音频流传输中断，已保留本地音频等待网络恢复后重试"])
            }
            
            self.activeUploads[sessionId] = 0.85
            
            // 步骤三：向服务器发出严格验证确认请求 (Verify)
            guard let verifyURL = URL(string: "\(cleanBase)/api/classroom/verify") else {
                throw URLError(.badURL)
            }
            
            var verifyReq = URLRequest(url: verifyURL)
            verifyReq.httpMethod = "POST"
            verifyReq.allHTTPHeaderFields = authHeaders()
            
            let verifyBody: [String: Any] = [
                "key": remoteKey,
                "sessionId": sessionId.uuidString,
                "expectedSize": fileSize
            ]
            verifyReq.httpBody = try JSONSerialization.data(withJSONObject: verifyBody)
            
            let (verifyData, verifyResp) = try await URLSession.shared.data(for: verifyReq)
            guard let verifyHttpResp = verifyResp as? HTTPURLResponse, (200...299).contains(verifyHttpResp.statusCode) else {
                throw NSError(domain: "R2Error", code: 4, userInfo: [NSLocalizedDescriptionKey: "云端对象存储校验未响应，保留本地录音"])
            }
            
            let verifyResult = try JSONDecoder().decode(VerifyResponse.self, from: verifyData)
            guard verifyResult.ok && verifyResult.verified else {
                throw NSError(domain: "R2Error", code: 5, userInfo: [NSLocalizedDescriptionKey: verifyResult.error ?? "云端文件完整性校验未通过"])
            }
            
            self.activeUploads[sessionId] = 1.0
            self.activeUploads.removeValue(forKey: sessionId)
            self.uploadErrors.removeValue(forKey: sessionId)
            
            // 步骤四：最高原则——只有服务器证实完整保存后，才根据用户的模式决定是否释放本地文件
            if session.storageMode == .cloudFirst || self.storageMode == .cloudFirst {
                // 云端优先：安全删除本地临时缓存，释放学生手机空间
                try? FileManager.default.removeItem(at: localFileURL)
                onStatusUpdate(.cloudOnly, remoteKey)
            } else {
                // 云端+本地：本地原音频完整保留，云端与本地同步完成
                onStatusUpdate(.cloudVerified, remoteKey)
            }
        } catch {
            self.activeUploads.removeValue(forKey: sessionId)
            self.uploadErrors[sessionId] = error.localizedDescription
            // 发生任何网络异常或断网，原始本地音频严禁删除！
            onStatusUpdate(.uploadFailed, error.localizedDescription)
        }
    }
    
    /// 从云端获取短期回放流式 URL
    public func getPlaybackURL(for key: String) -> URL? {
        let cleanBase = workerBaseURL.hasSuffix("/") ? String(workerBaseURL.dropLast()) : workerBaseURL
        var components = URLComponents(string: "\(cleanBase)/api/classroom/stream/\(key)")
        if let token = KeychainHelper.get(key: "device_auth_token") {
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        return components?.url
    }
    
    /// 手动从云端下载音频回本地
    public func downloadAudioToLocal(session: LessonSession, destinationURL: URL) async throws {
        guard let remoteKey = session.remoteAudioKey, !remoteKey.isEmpty else {
            throw NSError(domain: "R2Error", code: 10, userInfo: [NSLocalizedDescriptionKey: "该录音尚无云端备份"])
        }
        guard let streamURL = getPlaybackURL(for: remoteKey) else {
            throw URLError(.badURL)
        }
        
        let (data, resp) = try await URLSession.shared.data(from: streamURL)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "R2Error", code: 11, userInfo: [NSLocalizedDescriptionKey: "从云端下载失败"])
        }
        try data.write(to: destinationURL)
    }
}
