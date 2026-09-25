import XCTest
@testable import DownloadEngine

/// Tests for DASHSegmentResolver's three addressing modes.
///
/// Every test in the first group corresponds to a bug that was live in the
/// resolver — each one fails against the pre-fix implementation, which is the
/// only reason to trust that the fix does anything. The names say what breaks,
/// not just what's being called.
final class DASHSegmentResolverTests: XCTestCase {

    private let manifestURL = URL(string: "https://cdn.example.com/vod/manifest.mpd")!

    private func resolve(
        _ mpd: String,
        representationId: String? = nil,
        bandwidth: Int? = nil
    ) -> DASHSegmentResolver.ResolvedStream? {
        DASHSegmentResolver.resolve(
            mpdText: mpd, baseURL: manifestURL,
            representationId: representationId, bandwidth: bandwidth
        )
    }

    // MARK: - SegmentTimeline: $Time$ must advance across repeats

    /// `<S d r>` repeats describe *distinct* segments one duration apart. Holding
    /// $Time$ constant across them produced N copies of the first segment's URL —
    /// a download that reported success at the right segment count while
    /// containing the same four seconds over and over.
    func testTimelineRepeatsAdvanceTime() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT5S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" media="seg-$Time$.m4s" initialization="init.mp4">
                  <SegmentTimeline>
                    <S t="0" d="1000" r="4"/>
                  </SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.lastPathComponent), [
            "seg-0.m4s", "seg-1000.m4s", "seg-2000.m4s", "seg-3000.m4s", "seg-4000.m4s",
        ])
        XCTAssertEqual(Set(stream.segments).count, 5, "repeats must be distinct URLs")
    }

    /// A second `<S>` with no @t starts where the previous entry's last repeat
    /// ended, and a different @d has to carry through that arithmetic.
    func testTimelineImplicitStartTimeCarriesAcrossEntries() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT3S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" media="s$Time$.m4s">
                  <SegmentTimeline>
                    <S t="0" d="1000" r="1"/>
                    <S d="500" r="1"/>
                  </SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.lastPathComponent),
                       ["s0.m4s", "s1000.m4s", "s2000.m4s", "s2500.m4s"])
    }

    // MARK: - SegmentTimeline: r="-1" needs a duration to count towards

    /// `r="-1"` means "repeat to the end of the timeline", knowable only from the
    /// presentation duration. That value was captured during parsing but never
    /// stored on the Representation, so the repeat count always resolved to 0 and
    /// a full-length stream downloaded exactly one segment.
    func testNegativeRepeatExpandsToPresentationDuration() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" media="seg-$Time$.m4s">
                  <SegmentTimeline>
                    <S t="0" d="1000" r="-1"/>
                  </SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.count, 10)
        XCTAssertEqual(stream.segments.first?.lastPathComponent, "seg-0.m4s")
        XCTAssertEqual(stream.segments.last?.lastPathComponent, "seg-9000.m4s")
    }

    /// The duration has to be converted into the Representation's *own* timescale,
    /// which a Representation-level SegmentTemplate may override after the
    /// AdaptationSet has already declared one.
    func testNegativeRepeatUsesRepresentationLevelTimescale() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4" timescale="1000">
              <SegmentTemplate timescale="1000" media="aset-$Time$.m4s" duration="1000"/>
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="90000" media="rep-$Time$.m4s">
                  <SegmentTimeline>
                    <S t="0" d="90000" r="-1"/>
                  </SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        // 4s at timescale 90000 = 360000 ticks / 90000 per segment = 4 segments.
        // Reading the AdaptationSet's 1000 instead would give 4 ticks → 0 repeats.
        XCTAssertEqual(stream.segments.count, 4)
        XCTAssertEqual(stream.segments.map(\.lastPathComponent),
                       ["rep-0.m4s", "rep-90000.m4s", "rep-180000.m4s", "rep-270000.m4s"])
    }

    // MARK: - SegmentTimeline: startNumber

    /// Timeline mode hard-coded `$Number$` to start at 1, ignoring
    /// @startNumber — wrong URLs for every manifest that sets it.
    func testTimelineHonoursStartNumber() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT3S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" startNumber="7" media="chunk-$Number$.m4s">
                  <SegmentTimeline>
                    <S t="0" d="1000" r="2"/>
                  </SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.lastPathComponent),
                       ["chunk-7.m4s", "chunk-8.m4s", "chunk-9.m4s"])
    }

    // MARK: - SegmentBase: never hand back the manifest itself

    /// With no SegmentTemplate, SegmentList *or* BaseURL, there is nothing to
    /// download. The resolved base falls back to the manifest URL, so this used to
    /// return the .mpd itself as the media file — saving XML into a .mp4.
    func testBareRepresentationWithNoBaseURLResolvesToNothing() {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        XCTAssertNil(resolve(mpd))
    }

    /// The guard above must not break the legitimate single-file case: a
    /// Representation whose BaseURL *is* the media.
    func testSegmentBaseWithExplicitBaseURLResolvesToThatFile() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <BaseURL>video-1080p.mp4</BaseURL>
                <SegmentBase indexRange="0-999"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.absoluteString),
                       ["https://cdn.example.com/vod/video-1080p.mp4"])
    }

    /// A BaseURL inherited from an ancestor counts as explicit too.
    func testSegmentBaseInheritsExplicitBaseURLFromMPDLevel() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <BaseURL>https://media.example.net/assets/movie.mp4</BaseURL>
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000"/>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.absoluteString),
                       ["https://media.example.net/assets/movie.mp4"])
    }

    // MARK: - BaseURL text arriving in pieces

    /// XMLParser splits one text node across several foundCharacters callbacks at
    /// entity references. Resolving on each callback instead of accumulating meant
    /// the *last* fragment won, so a BaseURL containing any entity resolved to
    /// garbage. `&#100;` is a literal "d", so this element's text is
    /// "https://cdn.example.com/abcdef/" delivered in three pieces.
    func testBaseURLSplitAcrossCallbacksIsReassembled() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT2S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <BaseURL>https://cdn.example.com/abc&#100;ef/</BaseURL>
                <SegmentTemplate timescale="1000" duration="1000" media="s-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.absoluteString), [
            "https://cdn.example.com/abcdef/s-1.m4s",
            "https://cdn.example.com/abcdef/s-2.m4s",
        ])
    }

    // MARK: - Duration source: Period@duration fallback

    /// A static manifest may carry its duration on Period@duration instead of
    /// MPD@mediaPresentationDuration. Only the latter was read, so $Number$ mode
    /// computed a segment count of zero and the whole resolve failed.
    func testPeriodDurationUsedWhenMediaPresentationDurationAbsent() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static">
          <Period duration="PT8S">
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" duration="2000" media="s-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.count, 4)
        XCTAssertEqual(stream.totalDuration, 8)
    }

    // MARK: - Template expansion

    func testNumberTemplateWithFormatWidthAndIdentifiers() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="video_1" bandwidth="4200000">
                <SegmentTemplate timescale="1000" duration="2000"
                                 initialization="$RepresentationID$/init.mp4"
                                 media="$RepresentationID$/$Bandwidth$/$Number%05d$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.absoluteString), [
            "https://cdn.example.com/vod/video_1/4200000/00001.m4s",
            "https://cdn.example.com/vod/video_1/4200000/00002.m4s",
        ])
        XCTAssertEqual(stream.initSegmentURL?.absoluteString,
                       "https://cdn.example.com/vod/video_1/init.mp4")
    }

    // MARK: - SegmentList

    func testSegmentListResolvesExplicitURLsAgainstBaseURL() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT6S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <BaseURL>chunks/</BaseURL>
                <SegmentList timescale="1000" duration="2000">
                  <Initialization sourceURL="init.mp4"/>
                  <SegmentURL media="a.m4s"/>
                  <SegmentURL media="b.m4s"/>
                  <SegmentURL media="c.m4s"/>
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.map(\.absoluteString), [
            "https://cdn.example.com/vod/chunks/a.m4s",
            "https://cdn.example.com/vod/chunks/b.m4s",
            "https://cdn.example.com/vod/chunks/c.m4s",
        ])
        XCTAssertEqual(stream.initSegmentURL?.absoluteString,
                       "https://cdn.example.com/vod/chunks/init.mp4")
    }

    // MARK: - Representation selection

    func testExactRepresentationIdWins() throws {
        let stream = try XCTUnwrap(resolve(multiRepresentationMPD, representationId: "v_720"))
        XCTAssertTrue(stream.segments[0].absoluteString.contains("v_720"))
    }

    func testUnknownRepresentationIdFallsBackToClosestBandwidth() throws {
        let stream = try XCTUnwrap(resolve(multiRepresentationMPD, representationId: "nope", bandwidth: 2_400_000))
        XCTAssertTrue(stream.segments[0].absoluteString.contains("v_720"))
    }

    func testNoHintsPicksHighestBandwidth() throws {
        let stream = try XCTUnwrap(resolve(multiRepresentationMPD))
        XCTAssertTrue(stream.segments[0].absoluteString.contains("v_1080"))
    }

    private let multiRepresentationMPD = """
    <?xml version="1.0"?>
    <MPD type="static" mediaPresentationDuration="PT2S">
      <Period>
        <AdaptationSet mimeType="video/mp4">
          <SegmentTemplate timescale="1000" duration="2000" media="$RepresentationID$/$Number$.m4s"/>
          <Representation id="v_360" bandwidth="800000"/>
          <Representation id="v_720" bandwidth="2500000"/>
          <Representation id="v_1080" bandwidth="6000000"/>
        </AdaptationSet>
      </Period>
    </MPD>
    """

    // MARK: - Namespace prefixes

    /// Element names are matched on their local part, so a prefixed manifest
    /// (common from Shaka/GPAC packagers) parses identically.
    func testNamespacePrefixedElementsParse() throws {
        let mpd = """
        <?xml version="1.0"?>
        <dash:MPD xmlns:dash="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT2S">
          <dash:Period>
            <dash:AdaptationSet mimeType="video/mp4">
              <dash:Representation id="v0" bandwidth="1000000">
                <dash:SegmentTemplate timescale="1000" duration="1000" media="s-$Number$.m4s"/>
              </dash:Representation>
            </dash:AdaptationSet>
          </dash:Period>
        </dash:MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd))
        XCTAssertEqual(stream.segments.count, 2)
    }

    // MARK: - Malformed input

    func testGarbageInputReturnsNil() {
        XCTAssertNil(resolve("not xml at all"))
        XCTAssertNil(resolve("<MPD></MPD>"))
        XCTAssertNil(resolve(""))
    }

    /// A live manifest has no mediaPresentationDuration and an open-ended
    /// timeline. It must not produce a bogus segment list from a zero duration.
    func testDynamicManifestWithoutDurationDoesNotFabricateSegments() {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="dynamic" minimumUpdatePeriod="PT2S">
          <Period>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" duration="2000" media="s-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        XCTAssertNil(resolve(mpd))
    }

    /// Multi-Period manifests still resolve (one Period's worth) rather than
    /// failing — the documented current limitation. This test exists to catch an
    /// accidental behaviour change, not to endorse the truncation.
    func testMultiPeriodResolvesSinglePeriodWithoutFailing() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT4S">
          <Period id="p0">
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" duration="2000" media="p0/s-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="ad">
            <AdaptationSet mimeType="video/mp4">
              <Representation id="ad0" bandwidth="1000000">
                <SegmentTemplate timescale="1000" duration="2000" media="ad/s-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try XCTUnwrap(resolve(mpd, representationId: "v0"))
        XCTAssertTrue(stream.segments.allSatisfy { $0.absoluteString.contains("/p0/") })
    }

    // MARK: - Track selection (resolveTracks)

    private func tracks(
        _ mpd: String,
        representationId: String? = nil,
        bandwidth: Int? = nil,
        preferredAudioLanguage: String? = nil
    ) -> DASHSegmentResolver.ResolvedTracks? {
        DASHSegmentResolver.resolveTracks(
            mpdText: mpd, baseURL: manifestURL,
            representationId: representationId, bandwidth: bandwidth,
            preferredAudioLanguage: preferredAudioLanguage
        )
    }

    /// One video AdaptationSet at three bitrates, plus whatever audio sets the
    /// caller supplies — the ordinary shape of a real manifest. All seven
    /// real-world fixtures captured for this work keep audio separate, so this is
    /// the common case, not an exotic one.
    private func splitTrackMPD(audioSets: String) -> String {
        """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <BaseURL>https://cdn.example.com/vod/</BaseURL>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v-low" bandwidth="200000" codecs="avc1.42c00d">
                <SegmentTemplate timescale="1000" duration="5000" media="vl-$Number$.m4s"/>
              </Representation>
              <Representation id="v-mid" bandwidth="800000" codecs="avc1.4d401f">
                <SegmentTemplate timescale="1000" duration="5000" media="vm-$Number$.m4s"/>
              </Representation>
              <Representation id="v-high" bandwidth="4000000" codecs="avc1.640028">
                <SegmentTemplate timescale="1000" duration="5000" media="vh-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
        \(audioSets)
          </Period>
        </MPD>
        """
    }

    private let singleAudioSet = """
      <AdaptationSet mimeType="audio/mp4">
        <Representation id="a0" bandwidth="128000" codecs="mp4a.40.2">
          <SegmentTemplate timescale="1000" duration="5000" media="a0-$Number$.m4s"/>
        </Representation>
      </AdaptationSet>
    """

    func testSplitTracksAreBothResolved() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: singleAudioSet)))
        let audio = try XCTUnwrap(t.audio)
        XCTAssertEqual(t.video.segments.map(\.lastPathComponent), ["vh-1.m4s", "vh-2.m4s"])
        XCTAssertEqual(audio.segments.map(\.lastPathComponent), ["a0-1.m4s", "a0-2.m4s"])
        XCTAssertEqual(t.video.bandwidth, 4_000_000)
        XCTAssertEqual(audio.bandwidth, 128_000)
        XCTAssertNotEqual(audio.segments, t.video.segments)
    }

    /// The bug this whole entry point exists to prevent: a bandwidth hint near the
    /// audio bitrate used to select the *audio* Representation as the download,
    /// because matching ran across every Representation in the manifest. The
    /// result was a file containing sound and no picture, reported as a success.
    func testAudioRateBandwidthHintStillSelectsVideo() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: singleAudioSet), bandwidth: 130_000))
        XCTAssertEqual(t.video.segments.first?.lastPathComponent, "vl-1.m4s")
        XCTAssertEqual(t.audio?.bandwidth, 128_000)
    }

    func testBandwidthHintSelectsWithinVideoPool() throws {
        let mpd = splitTrackMPD(audioSets: singleAudioSet)
        XCTAssertEqual(try XCTUnwrap(tracks(mpd, bandwidth: 4_000_000)).video.segments.first?.lastPathComponent, "vh-1.m4s")
        XCTAssertEqual(try XCTUnwrap(tracks(mpd, bandwidth: 800_000)).video.segments.first?.lastPathComponent, "vm-1.m4s")
    }

    func testExplicitRepresentationIdOverridesPoolRestriction() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: singleAudioSet), representationId: "v-mid"))
        XCTAssertEqual(t.video.segments.first?.lastPathComponent, "vm-1.m4s")
    }

    func testVideoOnlyManifestHasNothingToMerge() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: "")))
        XCTAssertNil(t.audio)
    }

    /// A Representation whose codecs list names both a video and an audio codec is
    /// already complete. Merging a second audio track into it would be wrong.
    func testMuxedRepresentationGetsNoSecondAudioTrack() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <BaseURL>https://cdn.example.com/vod/</BaseURL>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="mux" bandwidth="900000" codecs="avc1.4d401f,mp4a.40.2">
                <SegmentTemplate timescale="1000" duration="5000" media="mx-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
        \(singleAudioSet)
          </Period>
        </MPD>
        """
        let t = try XCTUnwrap(tracks(mpd))
        XCTAssertNil(t.audio)
        XCTAssertEqual(t.video.segments.count, 2)
    }

    /// Podcast/radio DASH: the audio track *is* the download, so it becomes the
    /// primary rather than being treated as something to merge into a video that
    /// doesn't exist.
    func testAudioOnlyManifestYieldsAudioAsPrimary() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <BaseURL>https://cdn.example.com/vod/</BaseURL>
        \(singleAudioSet)
          </Period>
        </MPD>
        """
        let t = try XCTUnwrap(tracks(mpd))
        XCTAssertEqual(t.video.segments.map(\.lastPathComponent), ["a0-1.m4s", "a0-2.m4s"])
        XCTAssertNil(t.audio)
    }

    func testSubtitleAdaptationSetIsNotMistakenForAudio() throws {
        let subs = """
          <AdaptationSet mimeType="text/vtt" lang="en">
            <Representation id="s0" bandwidth="1000">
              <SegmentTemplate timescale="1000" duration="5000" media="sub-$Number$.vtt"/>
            </Representation>
          </AdaptationSet>
        """
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: singleAudioSet + subs)))
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "a0-1.m4s")
    }

    // MARK: - Audio selection among alternatives

    private let multiLanguageAudioSets = """
      <AdaptationSet mimeType="audio/mp4" lang="en">
        <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
        <Representation id="a-en-lo" bandwidth="64000" codecs="mp4a.40.2">
          <SegmentTemplate timescale="1000" duration="5000" media="aen-lo-$Number$.m4s"/>
        </Representation>
        <Representation id="a-en-hi" bandwidth="192000" codecs="mp4a.40.2">
          <SegmentTemplate timescale="1000" duration="5000" media="aen-hi-$Number$.m4s"/>
        </Representation>
      </AdaptationSet>
      <AdaptationSet mimeType="audio/mp4" lang="de">
        <Representation id="a-de" bandwidth="256000" codecs="mp4a.40.2">
          <SegmentTemplate timescale="1000" duration="5000" media="ade-$Number$.m4s"/>
        </Representation>
      </AdaptationSet>
    """

    /// Absent a preference, a player defaults to the manifest's first-declared
    /// language — so the 256k German track must not win on bitrate alone.
    func testNoPreferenceTakesFirstDeclaredLanguageAtHighestBitrate() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: multiLanguageAudioSets)))
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "aen-hi-1.m4s")
        XCTAssertEqual(t.audio?.bandwidth, 192_000)
        XCTAssertEqual(t.audioLanguage, "en")
    }

    func testPreferredLanguageWinsOverBitrate() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: multiLanguageAudioSets),
                                     preferredAudioLanguage: "de"))
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "ade-1.m4s")
        XCTAssertEqual(t.audioLanguage, "de")
    }

    /// An unmatched preference degrades to the next signal rather than to nothing:
    /// a language the manifest doesn't carry must not produce a silent file.
    func testUnmatchedLanguagePreferenceFallsBack() throws {
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: multiLanguageAudioSets),
                                     preferredAudioLanguage: "ja"))
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "aen-hi-1.m4s")
    }

    func testLanguageMatchingAcceptsRegionSuffix() throws {
        let sets = """
          <AdaptationSet mimeType="audio/mp4" lang="en-GB">
            <Representation id="a-gb" bandwidth="128000" codecs="mp4a.40.2">
              <SegmentTemplate timescale="1000" duration="5000" media="agb-$Number$.m4s"/>
            </Representation>
          </AdaptationSet>
        """
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: sets), preferredAudioLanguage: "en"))
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "agb-1.m4s")
    }

    /// `<Role value="main"/>` is the only thing distinguishing primary audio from
    /// descriptive audio or commentary. Without honouring it, the 256k
    /// audio-description track wins on bitrate and the download narrates itself.
    func testRoleMainBeatsHigherBitrateDescriptionTrack() throws {
        let sets = """
          <AdaptationSet mimeType="audio/mp4" lang="en">
            <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
            <Representation id="a-main" bandwidth="128000" codecs="mp4a.40.2">
              <SegmentTemplate timescale="1000" duration="5000" media="amain-$Number$.m4s"/>
            </Representation>
          </AdaptationSet>
          <AdaptationSet mimeType="audio/mp4" lang="en">
            <Role schemeIdUri="urn:mpeg:dash:role:2011" value="description"/>
            <Representation id="a-desc" bandwidth="256000" codecs="mp4a.40.2">
              <SegmentTemplate timescale="1000" duration="5000" media="adesc-$Number$.m4s"/>
            </Representation>
          </AdaptationSet>
        """
        let t = try XCTUnwrap(tracks(splitTrackMPD(audioSets: sets)))
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "amain-1.m4s")
    }

    // MARK: - Classification fallbacks

    /// Some manifests declare no mimeType on either level but do carry @codecs,
    /// which is enough to tell the tracks apart.
    func testCodecsClassifyTracksWhenMimeTypeIsAbsent() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <BaseURL>https://cdn.example.com/vod/</BaseURL>
            <AdaptationSet>
              <Representation id="v" bandwidth="900000" codecs="hvc1.2.4.L120.90">
                <SegmentTemplate timescale="1000" duration="5000" media="v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet>
              <Representation id="a" bandwidth="128000" codecs="opus">
                <SegmentTemplate timescale="1000" duration="5000" media="a-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let t = try XCTUnwrap(tracks(mpd))
        XCTAssertEqual(t.video.segments.first?.lastPathComponent, "v-1.m4s")
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "a-1.m4s")
    }

    /// `@contentType` holds the bare word ("video"/"audio"), not a MIME type —
    /// which is why classification matches on prefix rather than equality.
    func testContentTypeAttributeClassifiesTracks() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period>
            <BaseURL>https://cdn.example.com/vod/</BaseURL>
            <AdaptationSet contentType="video">
              <Representation id="v" bandwidth="900000">
                <SegmentTemplate timescale="1000" duration="5000" media="v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet contentType="audio">
              <Representation id="a" bandwidth="128000">
                <SegmentTemplate timescale="1000" duration="5000" media="a-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let t = try XCTUnwrap(tracks(mpd))
        XCTAssertEqual(t.video.segments.first?.lastPathComponent, "v-1.m4s")
        XCTAssertEqual(t.audio?.segments.first?.lastPathComponent, "a-1.m4s")
    }

    /// Audio is taken from the video's own Period. The higher-bitrate track in the
    /// next Period belongs to different media — merging it would splice an
    /// unrelated soundtrack onto the picture.
    func testAudioIsConfinedToTheChosenPeriod() throws {
        let mpd = """
        <?xml version="1.0"?>
        <MPD type="static" mediaPresentationDuration="PT10S">
          <Period id="p0">
            <BaseURL>https://cdn.example.com/p0/</BaseURL>
            <AdaptationSet mimeType="video/mp4">
              <Representation id="v0" bandwidth="900000" codecs="avc1.4d401f">
                <SegmentTemplate timescale="1000" duration="5000" media="v-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
            <AdaptationSet mimeType="audio/mp4">
              <Representation id="a0" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate timescale="1000" duration="5000" media="a-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
          <Period id="p1">
            <BaseURL>https://cdn.example.com/p1/</BaseURL>
            <AdaptationSet mimeType="audio/mp4">
              <Representation id="a1" bandwidth="999000" codecs="mp4a.40.2">
                <SegmentTemplate timescale="1000" duration="5000" media="a-$Number$.m4s"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let t = try XCTUnwrap(tracks(mpd, representationId: "v0"))
        let audio = try XCTUnwrap(t.audio)
        XCTAssertTrue(audio.segments.allSatisfy { $0.absoluteString.contains("/p0/") })
        XCTAssertEqual(audio.bandwidth, 128_000)
    }

    /// `resolve` is now a thin delegate over `resolveTracks`. It must keep
    /// returning the primary track — silently, which is exactly why callers that
    /// produce a file for a user should not use it.
    func testLegacyResolveReturnsPrimaryTrackOnly() throws {
        let mpd = splitTrackMPD(audioSets: singleAudioSet)
        let legacy = try XCTUnwrap(resolve(mpd))
        let t = try XCTUnwrap(tracks(mpd))
        XCTAssertEqual(legacy.segments, t.video.segments)
        XCTAssertEqual(legacy.segments.first?.lastPathComponent, "vh-1.m4s")
    }
}
