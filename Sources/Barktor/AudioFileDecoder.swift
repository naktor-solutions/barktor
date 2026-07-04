import AVFoundation
import Foundation

enum AudioFileDecoderError: LocalizedError {
    case unreadable(String)
    case tooLong(TimeInterval, limit: TimeInterval)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "Could not read this audio file (\(detail))."
        case .tooLong(let duration, let limit):
            let hours = Int(duration / 3600)
            let limitHours = Int(limit / 3600)
            return "This file is ~\(hours)h long — the limit is \(limitHours)h."
        case .empty:
            return "This audio file contains no audio."
        }
    }
}

// Decodes any AVAudioFile-readable audio (m4a, mp3, wav, aiff, caf, flac…)
// to the 16 kHz mono Float32 samples every engine consumes. This is the one
// shape WAVFile deliberately refuses to produce (it round-trips exactly what
// Barktor records); dropped files (B1) arrive in arbitrary formats.
enum AudioFileDecoder {
    // ~690 MB of Float32 at 16 kHz — the in-RAM ceiling one job may claim.
    static let maxDuration: TimeInterval = 3 * 3600

    static func decode16kMono(
        url: URL, maxDuration: TimeInterval = AudioFileDecoder.maxDuration
    ) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioFileDecoderError.unreadable(error.localizedDescription)
        }
        let source = file.processingFormat
        guard file.length > 0, source.sampleRate > 0 else { throw AudioFileDecoderError.empty }
        let duration = Double(file.length) / source.sampleRate
        guard duration <= maxDuration else {
            throw AudioFileDecoderError.tooLong(duration, limit: maxDuration)
        }

        guard
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: target)
        else { throw AudioFileDecoderError.unreadable("unsupported audio format") }

        let inCapacity: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inCapacity)
        else { throw AudioFileDecoderError.unreadable("could not allocate read buffer") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(duration * 16_000) + 16_000)
        var readError: Error?

        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)
            else { throw AudioFileDecoderError.unreadable("could not allocate output buffer") }
            var convertError: NSError?
            let status = converter.convert(to: outBuffer, error: &convertError) { _, outStatus in
                do {
                    inBuffer.frameLength = 0
                    try file.read(into: inBuffer, frameCount: inCapacity)
                } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard inBuffer.frameLength > 0 else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if let convertError {
                throw AudioFileDecoderError.unreadable(convertError.localizedDescription)
            }
            if let readError {
                throw AudioFileDecoderError.unreadable(readError.localizedDescription)
            }
            if outBuffer.frameLength > 0 {
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
            }
            switch status {
            case .haveData:
                continue
            case .endOfStream, .inputRanDry:
                guard !samples.isEmpty else { throw AudioFileDecoderError.empty }
                return samples
            case .error:
                throw AudioFileDecoderError.unreadable("conversion failed")
            @unknown default:
                throw AudioFileDecoderError.unreadable("conversion failed")
            }
        }
    }
}
