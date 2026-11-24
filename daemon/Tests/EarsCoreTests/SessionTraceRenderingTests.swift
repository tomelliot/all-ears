import Foundation
import Testing

@testable import EarsCore

@Suite("SessionTraceRendering")
struct SessionTraceRenderingTests {
  /// 2026-11-22T17:00:37Z.
  private let started = Instant(secondsSinceEpoch: 1_795_366_837)

  /// A one-remote Jitsi call: a muted track that was never admitted, and a
  /// track admitted as `t1` and linked to platform id `4494e60c` ('a').
  private static let jitsiLog = """
    {"schema":1,"type":"track-appeared","t":1,"trackId":"06fd31a8-0000-4000-8000-000000000001","seam":"receiver-track","muted":true,"origin":"remote"}
    {"schema":1,"type":"deferred","t":1,"trackId":"06fd31a8-0000-4000-8000-000000000001","seam":"receiver-track","reason":"muted at dispatch"}
    {"schema":1,"type":"track-appeared","t":2,"trackId":"a54dcf0b-0000-4000-8000-000000000002","seam":"receiver-track","muted":true,"origin":"remote"}
    {"schema":1,"type":"track-unmuted","t":3,"trackId":"a54dcf0b-0000-4000-8000-000000000002"}
    {"schema":1,"type":"admitted","t":4,"trackId":"a54dcf0b-0000-4000-8000-000000000002","seam":"receiver-track","participantId":"t1","generation":1}
    {"schema":1,"type":"identity-link","t":4,"trackId":"a54dcf0b-0000-4000-8000-000000000002","captureId":"t1","participantId":"4494e60c"}
    {"schema":1,"type":"audio-onset","t":5,"participantId":"t1","trackId":"a54dcf0b-0000-4000-8000-000000000002","state":"start","framePeak":0.03}
    {"schema":1,"type":"audio-onset","t":6,"participantId":"t1","trackId":"a54dcf0b-0000-4000-8000-000000000002","state":"stop","framePeak":0.001}
    {"schema":1,"type":"audio-onset","t":7,"participantId":"t1","trackId":"a54dcf0b-0000-4000-8000-000000000002","state":"start","framePeak":0.02}
    not json
    {"schema":2,"type":"admitted","trackId":"a54dcf0b-0000-4000-8000-000000000002","participantId":"t9"}
    """

  private func session(
    attendees: [SessionAttendee], speakers: [SessionSpeaker], warnings: [String] = []
  ) -> Session {
    Session(
      id: "46aa6491-02b8-403f-b6f5-97238c79b797",
      identity: SessionIdentity(platform: "jitsi", externalID: "meet.jit.si/room"),
      title: "Room", state: .ended, started: started, ended: started.advanced(by: 22),
      attendees: attendees, speakers: speakers, warnings: warnings,
      sources: [SourceID("mic"), SourceID("browser:jitsi:t1")])
  }

  private func segment(_ source: String, _ speaker: String, _ text: String) -> TranscriptSegment {
    TranscriptSegment(
      source: SourceID(source), speaker: speaker,
      segment: Segment(start: 0, end: 1, text: text, words: [], confidence: nil))
  }

  @Test("the track log folds per track, skipping foreign schemas and malformed lines")
  func parsesTracks() {
    #expect(
      AttributionTrackLog.parse(jsonl: Self.jitsiLog) == [
        AttributionTrack(
          trackId: "06fd31a8-0000-4000-8000-000000000001", origin: "remote",
          deferredReason: "muted at dispatch"),
        AttributionTrack(
          trackId: "a54dcf0b-0000-4000-8000-000000000002", origin: "remote", captureId: "t1",
          platformIDs: ["4494e60c"],
          speechOnsets: 2),
      ])
  }

  @Test("a correlated one-remote call renders the full chain and flags only the missing self")
  func rendersJitsiCall() {
    let session = session(
      attendees: [
        SessionAttendee(
          id: "t1", displayName: "", source: SourceID("browser:jitsi:t1"), origin: .synthetic),
        SessionAttendee(
          id: "4494e60c", displayName: "a", source: SourceID("browser:jitsi:t1"),
          origin: .platform),
      ],
      speakers: [
        SessionSpeaker(source: SourceID("browser:jitsi:t1"), name: "a", confidence: .correlated)
      ],
      warnings: ["could not identify which roster entry is you"])
    let text = SessionTraceRendering.render(
      session: session, tracks: AttributionTrackLog.parse(jsonl: Self.jitsiLog),
      segments: [segment("browser:jitsi:t1", "a", "Okay. How about that?")])

    #expect(
      text == """
        Room — 46aa6491  platform=jitsi
          sources  mic, browser:jitsi:t1
          ⚠ could not identify which roster entry is you

        attendees (daemon roster)
          t1        origin=synthetic  self=false  name=''   source=browser:jitsi:t1
          4494e60c  origin=platform   self=false  name='a'  source=browser:jitsi:t1

        speakers (transcript labels)
          browser:jitsi:t1  -> 'a'  (correlated)

        tracks (browser attribution log)
          06fd31a8  origin=remote  capture=-   platform_id=-         speech_onsets=0  (never admitted: deferred, muted at dispatch)
          a54dcf0b  origin=remote  capture=t1  platform_id=4494e60c  speech_onsets=2

        chain (track -> capture -> platform id -> name -> label)
          a54dcf0b  -> t1  -> 4494e60c  -> 'a'  -> 'a'  (browser:jitsi:t1)

        words per source / label (transcript.json)
          browser:jitsi:t1  'a'  4

        problems
          ⚠ no attendee has self=true — the local participant is unknown
        """)
  }

  @Test("absent attribution log and transcript render as absences, not empties")
  func rendersAbsentFiles() {
    let text = SessionTraceRendering.render(
      session: session(attendees: [], speakers: []), tracks: nil, segments: nil)
    #expect(text.contains("tracks (browser attribution log)\n  no attribution.jsonl"))
    #expect(text.contains("(transcript.json)\n  no transcript.json"))
    #expect(text.hasSuffix("problems\n  none"))
  }

  @Test("each broken link in the chain is flagged")
  func flagsProblems() {
    let log = """
      {"schema":1,"type":"admitted","t":1,"trackId":"aaaaaaaa-0000-4000-8000-000000000003","participantId":"t1","generation":1}
      {"schema":1,"type":"identity-link","t":2,"trackId":"aaaaaaaa-0000-4000-8000-000000000003","captureId":"t1","participantId":"p-unnamed"}
      {"schema":1,"type":"admitted","t":3,"trackId":"bbbbbbbb-0000-4000-8000-000000000004","participantId":"t2","generation":1}
      {"schema":1,"type":"audio-onset","t":4,"participantId":"t2","trackId":"bbbbbbbb-0000-4000-8000-000000000004","state":"start","framePeak":0.1}
      {"schema":1,"type":"admitted","t":5,"trackId":"cccccccc-0000-4000-8000-000000000005","participantId":"t3","generation":1}
      {"schema":1,"type":"identity-link","t":6,"trackId":"cccccccc-0000-4000-8000-000000000005","captureId":"t3","participantId":"p-ghost"}
      """
    var session = session(
      attendees: [
        SessionAttendee(
          id: "p-unnamed", displayName: "", source: SourceID("browser:jitsi:t1"),
          origin: .platform),
        SessionAttendee(
          id: "p-bo", displayName: "Bo", source: SourceID("browser:jitsi:t1"), origin: .platform),
        SessionAttendee(
          id: "p-cy", displayName: "Cy", source: SourceID("browser:jitsi:t1"), origin: .platform),
        SessionAttendee(id: "p-me", displayName: "Me", origin: .platform, isLocal: true),
      ],
      speakers: [
        SessionSpeaker(source: SourceID("browser:jitsi:t2"), name: "Bo", confidence: .inferred)
      ])
    session.sources += [SourceID("browser:jitsi:t2"), SourceID("browser:jitsi:t3")]

    let problems = SessionTraceRendering.problems(
      session: session, tracks: AttributionTrackLog.parse(jsonl: log),
      chain: SessionTraceRendering.chainLinks(
        session: session, tracks: AttributionTrackLog.parse(jsonl: log)),
      words: SessionTraceRendering.wordCounts([
        segment("browser:jitsi:t2", "Speaker 2", "hello there"),
        segment("browser:jitsi:t3", "Unknown", "one two three"),
        segment("mic", "Me", "hi"),
      ]))

    #expect(
      problems == [
        "track bbbbbbbb (capture t2) carried 1 speech onset but was never linked to a platform id",
        "platform id p-unnamed has no display name in the roster",
        "platform id p-ghost (track cccccccc) has no roster row",
        "browser:jitsi:t1 is claimed by 'Bo' and 'Cy'",
        "browser:jitsi:t2 is labelled 'Bo' (inferred) but no identity link names it",
        "3 words on browser:jitsi:t3 have no speaker map entry",
        "2 words on browser:jitsi:t2 are labelled 'Speaker 2', but the speaker map says 'Bo'",
      ])
  }
}

@Test("a UUID track id is shortened; a Jitsi slot id is kept whole")
func shortTrackIDKeepsSlotIDsDistinct() {
  #expect(SessionTraceRendering.shortTrackID("a54dcf0b-c99f-4bce-bc67-c75eeb31ea7d") == "a54dcf0b")
  #expect(SessionTraceRendering.shortTrackID("remote-audio-1") == "remote-audio-1")
  #expect(SessionTraceRendering.shortTrackID("remote-audio-2") == "remote-audio-2")
}
