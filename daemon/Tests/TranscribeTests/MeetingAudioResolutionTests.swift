import EarsDataStore
import Testing

@testable import transcribe

/// Pure coverage of ``MeetingAudioResolution`` — the store-selection and
/// empty-diagnosis rules for `transcribe --meeting` (all-ears issue #20),
/// exercised without any data root on disk.
@Suite("MeetingAudioResolution")
struct MeetingAudioResolutionTests {
  private func probe(exists: Bool, chunks: Int, speech: Int = 0) -> SegmentedAudioReader.RangeProbe
  {
    SegmentedAudioReader.RangeProbe(
      sourceExists: exists, chunksInRange: chunks, speechIntervals: speech)
  }

  @Test("prefers the per-meeting store when it holds chunks")
  func prefersMeetingWhenItHasChunks() {
    let chosen = MeetingAudioResolution.chooseStore(
      meeting: probe(exists: true, chunks: 2), ring: probe(exists: true, chunks: 5))
    #expect(chosen == .meeting)
  }

  @Test("falls back to the ring store when the per-meeting store has no chunks")
  func fallsBackToRingWhenMeetingEmpty() {
    // The exact issue #20 shape: a per-meeting dir exists but is empty for the
    // window, while the ring holds the audio.
    let chosen = MeetingAudioResolution.chooseStore(
      meeting: probe(exists: true, chunks: 0), ring: probe(exists: true, chunks: 3))
    #expect(chosen == .ring)
  }

  @Test("falls back to the ring store when there is no per-meeting dir at all (e.g. mic)")
  func fallsBackToRingWhenNoMeetingDir() {
    let chosen = MeetingAudioResolution.chooseStore(
      meeting: probe(exists: false, chunks: 0), ring: probe(exists: true, chunks: 3))
    #expect(chosen == .ring)
  }

  @Test("keeps the per-meeting store when neither has chunks but the per-meeting dir exists")
  func keepsMeetingWhenBothEmptyButMeetingExists() {
    let chosen = MeetingAudioResolution.chooseStore(
      meeting: probe(exists: true, chunks: 0), ring: probe(exists: true, chunks: 0))
    #expect(chosen == .meeting)
  }

  @Test("returns nil when neither store holds the source")
  func nilWhenNeitherStoreExists() {
    let chosen = MeetingAudioResolution.chooseStore(
      meeting: probe(exists: false, chunks: 0), ring: probe(exists: false, chunks: 0))
    #expect(chosen == nil)
  }

  @Test("empty reason: store missing when no store was chosen")
  func emptyReasonStoreMissing() {
    #expect(
      MeetingAudioResolution.emptyReason(
        storeExists: false, chunksInRange: 0, speechIntervals: 0, sliceCount: 0) == "store missing")
  }

  @Test("empty reason: no chunks in range")
  func emptyReasonNoChunks() {
    #expect(
      MeetingAudioResolution.emptyReason(
        storeExists: true, chunksInRange: 0, speechIntervals: 0, sliceCount: 0)
        == "no chunks in range")
  }

  @Test("empty reason: chunks but no speech intervals")
  func emptyReasonNoSpeech() {
    #expect(
      MeetingAudioResolution.emptyReason(
        storeExists: true, chunksInRange: 4, speechIntervals: 0, sliceCount: 0)
        == "chunks but no speech intervals")
  }

  @Test("empty reason is nil when the source produced slices")
  func emptyReasonNilWhenSlicesProduced() {
    #expect(
      MeetingAudioResolution.emptyReason(
        storeExists: true, chunksInRange: 4, speechIntervals: 2, sliceCount: 1) == nil)
  }
}
