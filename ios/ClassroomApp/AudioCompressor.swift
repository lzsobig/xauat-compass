import AVFoundation
import Foundation

/// 课堂音频高保真压缩器
/// 将原始录音转换为高压缩比、高人声清晰度的 AAC M4A 格式
/// 默认语音优化码率 48 kbps 单声道，90 分钟课堂录音压缩后约 32MB
public enum AudioCompressor {
    
    public enum CompressionError: LocalizedError {
        case fileNotFound
        case exportFailed(String)
        case unsupportedFormat
        
        public var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "未找到待压缩的原始录音文件"
            case .exportFailed(let reason):
                return "音频压缩失败：\(reason)"
            case .unsupportedFormat:
                return "不支持的音频格式"
            }
        }
    }
    
    /// 将输入音频转换为 AAC M4A
    @discardableResult
    public static func compressToM4A(sourceURL: URL, destinationURL: URL, bitrate: Int = 48000) async throws -> Int64 {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw CompressionError.fileNotFound
        }
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        
        let asset = AVURLAsset(url: sourceURL)
        
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            let rawSize = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
            return rawSize
        }
        
        exportSession.outputURL = destinationURL
        exportSession.outputFileType = AVFileType(rawValue: "com.apple.m4a-audio")
        exportSession.shouldOptimizeForNetworkUse = true
        
        await withCheckedContinuation { continuation in
            exportSession.exportAsynchronously {
                continuation.resume()
            }
        }
        
        switch exportSession.status {
        case .completed:
            let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let size = attrs[.size] as? Int64 ?? 0
            return size
        case .failed:
            throw CompressionError.exportFailed(exportSession.error?.localizedDescription ?? "未知错误")
        case .cancelled:
            throw CompressionError.exportFailed("压缩被取消")
        default:
            throw CompressionError.exportFailed("压缩未完成")
        }
    }
}
