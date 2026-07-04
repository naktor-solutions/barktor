import AVFoundation
import Foundation
import Testing

@testable import Barktor

struct AudioFileDecoderTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-\(UUID().uuidString).\(ext)")
    }

    // Writes `seconds` of a 440 Hz sine at the given format. AVAudioFile
    // handles the encode (PCM WAV or AAC m4a) via AudioToolbox.
    private func writeFixture(
        to url: URL, seconds: Double, sampleRate: Double, channels: AVAudioChannelCount,
        settings: [String: Any]
    ) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                channels: channels, interleaved: false)
        else { throw AudioFileDecoderError.unreadable("fixture format") }
        let file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw AudioFileDecoderError.unreadable("fixture buffer") }
        buffer.frameLength = frames
        for ch in 0..<Int(channels) {
            let data = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
            }
        }
        try file.write(from: buffer)
    }

    @Test func decodesStereo44kWAVTo16kMono() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(
            to: url, seconds: 1.0, sampleRate: 44_100, channels: 2,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ])
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        // 1 s of audio → ~16 000 samples (resampler edges allow slack).
        #expect(abs(samples.count - 16_000) < 200)
        // A sine at half amplitude survives the downmix — not silence.
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test func decodesM4A() throws {
        let url = tempURL("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(
            to: url, seconds: 1.0, sampleRate: 44_100, channels: 1,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
            ])
        let samples = try AudioFileDecoder.decode16kMono(url: url)
        // AAC pads with priming/remainder frames; allow generous slack.
        #expect(abs(samples.count - 16_000) < 2_000)
    }

    @Test func corruptFileThrowsUnreadable() throws {
        let url = tempURL("mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data((0..<1024).map { _ in UInt8.random(in: 0...255) }).write(to: url)
        #expect(throws: (any Error).self) {
            try AudioFileDecoder.decode16kMono(url: url)
        }
    }

    @Test func overlongFileThrowsTooLong() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(
            to: url, seconds: 2.0, sampleRate: 16_000, channels: 1,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ])
        #expect(throws: (any Error).self) {
            // 2 s fixture against a 1 s cap → .tooLong without a 3-hour fixture.
            try AudioFileDecoder.decode16kMono(url: url, maxDuration: 1.0)
        }
    }
}
