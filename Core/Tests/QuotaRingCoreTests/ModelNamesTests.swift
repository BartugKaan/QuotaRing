import Testing

@testable import QuotaRingCore

@Suite struct ModelNamesTests {
    @Test(
        arguments: [
            ("claude-opus-4-8", "Opus 4.8"),
            ("claude-opus-4-5-20251101", "Opus 4.5"),
            ("claude-haiku-4-5-20251001", "Haiku 4.5"),
            ("claude-sonnet-4-5-20250929", "Sonnet 4.5"),
            ("claude-fable-5", "Fable 5"),
            ("claude-opus-5-5", "Opus 5.5"),
            ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
            ("claude-3-opus-20240229", "Opus 3"),
            ("claude-opus-4-1-20250805", "Opus 4.1"),
            ("claude-sonnet", "Sonnet"),
            ("claude-opus-4-8-thinking", "Opus 4.8"),
        ])
    func familyAndVersion(modelID: String, expected: String) {
        #expect(ModelNames.family(modelID) == expected)
    }

    @Test(arguments: ["gpt-x", "Unknown", "<synthetic>", "", "claude-", "claude-4-5", "Claude-opus-4-8", "opus-4-8"])
    func idsWithoutAClaudeFamilyAreReturnedUnchanged(modelID: String) {
        #expect(ModelNames.family(modelID) == modelID)
    }

    @Test func differentSnapshotsOfOneModelShareAFamily() {
        #expect(ModelNames.family("claude-opus-4-5-20251101") == ModelNames.family("claude-opus-4-5"))
    }
}
