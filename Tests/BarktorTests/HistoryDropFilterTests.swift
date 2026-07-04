import Foundation
import Testing

@testable import Barktor

struct HistoryDropFilterTests {
    @Test func keepsAudioExtensionsDropsTheRest() {
        let urls = [
            URL(fileURLWithPath: "/tmp/nota.m4a"),
            URL(fileURLWithPath: "/tmp/cancion.mp3"),
            URL(fileURLWithPath: "/tmp/grabacion.wav"),
            URL(fileURLWithPath: "/tmp/documento.pdf"),
            URL(fileURLWithPath: "/tmp/video.mp4"),
            URL(fileURLWithPath: "/tmp/sin-extension"),
        ]
        let audio = HistoryView.audioURLs(from: urls)
        #expect(audio.map(\.lastPathComponent) == ["nota.m4a", "cancion.mp3", "grabacion.wav"])
    }
}
