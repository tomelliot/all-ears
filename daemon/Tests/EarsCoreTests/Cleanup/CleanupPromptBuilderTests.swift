import Testing

@testable import EarsCore

@Suite("CleanupPromptBuilder")
struct CleanupPromptBuilderTests {
  @Test("the dynamic suffix is exactly the transcript text, unwrapped")
  func dynamicSuffixIsRawTranscript() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "so um the deploy went out last night")
    #expect(prompt.dynamicSuffix == "so um the deploy went out last night")
  }

  @Test("the stable prefix is identical across calls with different transcripts")
  func stablePrefixIsStableAcrossCalls() {
    let builder = CleanupPromptBuilder(vocabulary: ["kubectl", "Priya Raman"])
    let first = builder.build(transcript: "first segment text")
    let second = builder.build(transcript: "a completely different second segment")
    #expect(first.stablePrefix == second.stablePrefix)
    #expect(first.stablePrefix != first.dynamicSuffix)
  }

  @Test("the stable prefix lists every vocabulary term as a correction backstop")
  func stablePrefixListsVocabulary() {
    let builder = CleanupPromptBuilder(vocabulary: ["kubectl", "Priya Raman"])
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.contains("kubectl"))
    #expect(prompt.stablePrefix.contains("Priya Raman"))
  }

  @Test("an empty vocabulary produces no vocabulary section")
  func emptyVocabularyOmitsSection() {
    let builder = CleanupPromptBuilder(vocabulary: [])
    let prompt = builder.build(transcript: "text")
    #expect(!prompt.stablePrefix.contains("Known words"))
  }

  @Test("the default instructs keeping filler words")
  func defaultKeepsFiller() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.lowercased().contains("keep filler"))
    #expect(!prompt.stablePrefix.lowercased().contains("remove filler"))
  }

  @Test("removeFiller opts into filler removal instructions")
  func removeFillerOptsIn() {
    let builder = CleanupPromptBuilder(removeFiller: true)
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.lowercased().contains("remove filler"))
  }

  @Test("the stable prefix instructs a minimal-change edit")
  func instructsMinimalChange() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "text")
    #expect(prompt.stablePrefix.lowercased().contains("smallest"))
  }

  @Test("fullText concatenates the prefix and suffix")
  func fullTextConcatenates() {
    let builder = CleanupPromptBuilder()
    let prompt = builder.build(transcript: "the transcript")
    #expect(prompt.fullText == prompt.stablePrefix + "the transcript")
  }
}
