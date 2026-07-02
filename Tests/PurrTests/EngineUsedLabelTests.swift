import Testing

@testable import Purr

struct EngineUsedLabelTests {
    @Test func parakeetIsBareIdentifier() {
        #expect(AppCoordinator.engineUsedLabel(engine: .parakeet, modelName: "ignored") == "parakeet")
    }

    @Test func whisperCarriesModelName() {
        #expect(
            AppCoordinator.engineUsedLabel(engine: .whisper, modelName: "openai_whisper-small")
                == "whisper:openai_whisper-small")
    }
}
