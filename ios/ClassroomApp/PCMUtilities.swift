import Foundation

// MARK: - PCM 转 WAV 工具函数

public func pcmToWav(samples: [Int16], sampleRate: Int = 16000) -> Data {
    var data = Data()
    let byteRate = sampleRate * 2
    let dataSize = samples.count * 2
    let chunkSize = 36 + dataSize
    
    // RIFF
    data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
    var val32 = UInt32(chunkSize).littleEndian
    data.append(Data(bytes: &val32, count: 4))
    // WAVE
    data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
    
    // fmt subchunk
    data.append(contentsOf: [0x66, 0x6d, 0x74, 0x20])
    var subchunk1Size = UInt32(16).littleEndian
    data.append(Data(bytes: &subchunk1Size, count: 4))
    var audioFormat = UInt16(1).littleEndian // PCM
    data.append(Data(bytes: &audioFormat, count: 2))
    var numChannels = UInt16(1).littleEndian // Mono
    data.append(Data(bytes: &numChannels, count: 2))
    var sr = UInt32(sampleRate).littleEndian
    data.append(Data(bytes: &sr, count: 4))
    var br = UInt32(byteRate).littleEndian
    data.append(Data(bytes: &br, count: 4))
    var blockAlign = UInt16(2).littleEndian
    data.append(Data(bytes: &blockAlign, count: 2))
    var bitsPerSample = UInt16(16).littleEndian
    data.append(Data(bytes: &bitsPerSample, count: 2))
    
    // data subchunk
    data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
    var ds = UInt32(dataSize).littleEndian
    data.append(Data(bytes: &ds, count: 4))
    
    samples.withUnsafeBufferPointer { ptr in
        data.append(Data(buffer: ptr))
    }
    return data
}

