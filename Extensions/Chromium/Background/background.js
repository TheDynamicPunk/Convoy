const NATIVE_HOST = 'io.github.thedynamicpunk.convoy.native';
let port = null;
let detectedMedia = [];

// Matches the fallback error string NativeMessagingHost.relayToApp() sends
// back when it can't reach the app's IPC socket at all (port file missing
// or connect() failed) — i.e. the app isn't running, as opposed to the app
// running but returning its own real error. Used to distinguish "prompt the
// user to open Convoy" from every other kind of failure.
const APP_NOT_RUNNING_ERROR = 'Convoy app not running';
const OPEN_APP_NOTIFICATION_ID = 'convoy-app-not-running';
// The most recent downloadRequest payload, kept only so it can be resent
// automatically once the user chooses to open the app from the prompt.
// Best-effort, single-slot — if several downloads fail while the app is
// closed, only the latest is retried; the rest still show nothing, matching
// the non-goal of building a full retry queue here.
let pendingRetryPayload = null;

// Tracks request IDs that have already been handed off to the native host.
// sendDownloadRequest has two independent retry paths that can both succeed
// for the same original request:
//   1. The port-reconnect path: when port===null at call time, a 100ms
//      setTimeout reschedules the same call — if the port comes back in
//      that window it fires.
//   2. The pendingRetryPayload path: openAppAndRetry() replays whatever
//      was last stashed, triggered by the user clicking "Open Convoy".
// Without coordination, both paths can fire for the same request and the
// app receives two identical download tasks. The fix: stamp each logical
// request with a UUID on first call, check before postMessage, and whichever
// path fires first marks the ID as consumed — the second is a silent no-op.
// IDs expire after 30 s so the set doesn't grow indefinitely.
const sentRequestIds = new Set();

// General-purpose recent-request tracker, per tab — not YouTube-specific.
// A blob: download always started life as a real network fetch a moment
// earlier (the page had to actually get the bytes from somewhere before it
// could wrap them in a Blob). We keep a short rolling window of real,
// non-HTML responses per tab so that when a blob: download fires, we can
// resolve it back to the real URL that produced it — instead of giving up.
const recentRequestsByTab = new Map(); // tabId -> [{ url, contentType, size, at }]
const RECENT_WINDOW_MS = 8000;
const RECENT_MAX_PER_TAB = 15;

// Step 1 of client-side sniffing for non-ytdlp-strategy sites (see
// SITE_STRATEGIES in video-latch.js). Deliberately a SEPARATE store from
// recentRequestsByTab above, not a shared one, because the two have
// opposite lifetime requirements: blob-resolution only cares about "what
// was requested in the last ~8 seconds" and purges aggressively (findMatch
// picks the most recent), while this needs to persist "what media has this
// page loaded" for as long as the tab is open, so the panel has something
// to show if the user hovers the video a while after playback started —
// jamming both into one capped rolling window would mean whichever purges
// first evicts the other's data.
//
// Populated by the SAME onHeadersReceived listener below (one webRequest
// listener doing two classifications on the same response, not two
// listeners each re-parsing headers) but filtered much more narrowly:
// recentRequestsByTab tracks "everything that isn't HTML" (deliberately
// broad, since a blob's source could be nearly any content-type);
// detectedMediaByTab ONLY keeps HLS/DASH manifests (.m3u8/.mpd) — nothing
// else. This was originally broader (also tried to catch "direct"
// video/audio-content-type responses as standalone downloadable files),
// but that's actually unworkable: a fragmented/CMAF-segmented stream's
// individual chunks are served with the *exact same* Content-Type
// (video/mp4, audio/mp4) as a genuine single-file video — there is no way
// to tell "this response is one whole file" from "this response is one of
// 400 chunks of a stream" by content-type alone, only the manifest knows
// that. Confirmed the hard way: testing against a real CMAF/fMP4 HLS
// stream flooded the panel with a few hundred "Original" rows, one per
// segment. A genuinely standalone file (<video src="movie.mp4">) is
// already caught fine by collectSources()'s DOM/currentSrc scan in
// video-latch.js — that's the right mechanism for it, since the browser's
// own player element points straight at the one real URL. Network
// sniffing's job is narrowed to exactly what DOM scanning can't see: the
// manifest URL that's only ever referenced from inside a player's JS, never
// placed on the element. Parsing that manifest for real quality variants
// (rather than one opaque "HLS stream"/"DASH stream" row) is the next step,
// not this one.
// Why the last enriched request went without cookies: 'noPermission', or
// null when it carried them. Read only to explain an auth
// failure — see the downloadFailed handler.
let lastRequestCookiesSkipped = null;

// The popup's master switch, default on. Off means Chrome keeps its own
// downloads and the shortcut does nothing; the context menu still works,
// since using it is an explicit request.
async function isCaptureEnabled() {
  const { captureEnabled } = await chrome.storage.local.get('captureEnabled');
  return captureEnabled !== false;
}

const detectedMediaByTab = new Map(); // tabId -> [{ url, contentType, size, kind, at }]
const DETECTED_MEDIA_MAX_PER_TAB = 25;

// content-type sniffing: modern HLS/DASH manifests are frequently served
// with a generic or even absent content-type (application/octet-stream, or
// nothing at all), so the URL's extension is checked as a fallback
// whenever the header alone isn't conclusive — exactly the situation
// yt-dlp's own GenericIE extractor handles the same way for the same
// reason (see the research report on non-YouTube sniffing).
//
// Split into 'hls'/'dash' rather than one generic 'manifest' kind because
// the two formats need different parsers downstream (parseHlsManifest vs
// parseDashManifest) — knowing which one this is up front avoids sniffing
// the content a second time just to dispatch.
function classifyMediaResponse(url, contentType) {
  if (/application\/dash\+xml/i.test(contentType) || /\.mpd(\?|$)/i.test(url)) return 'dash';
  if (/application\/(vnd\.apple\.mpegurl|x-mpegurl)|audio\/mpegurl/i.test(contentType) || /\.m3u8(\?|$)/i.test(url)) return 'hls';
  return null;
}

// A best-effort "these files probably belong to the same underlying video"
// signal — used to bundle a video's own quality variants and audio track
// together, and keep them separate from an unrelated video's files detected
// on the same page. Not a guess about timing: CDNs overwhelmingly colocate
// one video's renditions under one directory. Confirmed against a real
// capture: a master playlist, every quality variant, and a split-out audio
// track all shared the exact same CDN directory path; a different video on
// the same page had a completely different content hash and directory.
// video-latch.js uses this as the actual grouping/filtering mechanism for a page with more
// than one active video (e.g. Pinterest's related-pins feed autoplaying
// several previews at once) — timing is only used there to find which group
// belongs to a specific element in the first place, not to filter every
// individual file. Not a guarantee for every possible CDN layout, but it's a
// real, deterministic signal rather than a proximity-in-time guess.
function groupKeyForManifest(url) {
  try {
    const u = new URL(url);
    const dir = u.pathname.slice(0, u.pathname.lastIndexOf('/') + 1);
    return u.origin + dir;
  } catch {
    return url;
  }
}

// Parsed-variant cache, keyed by manifest URL. Resolution now begins as soon
// as the manifest is detected so the content script can surface its latch
// without waiting for a hover. The panel still reads this cache, so opening
// it remains instant. `null` is cached too, preventing repeat fetches for an
// unsupported manifest shape.
const parsedManifestsByUrl = new Map(); // manifestUrl -> { variants, durationSec } | null

// Fetches and parses an HLS (.m3u8) or DASH (.mpd) manifest for its real
// quality variants — this is what turns one opaque "HLS stream"/"DASH
// stream" row into an actual bitrate ladder. Runs in the background script
// specifically so it can use the extension's own <all_urls> host
// permission to fetch cross-origin without hitting the page's CORS
// restrictions — a fetch from the content script's world would be subject
// to those, a fetch from here isn't.
//
// Both parsers return the same shape, { variants, durationSec }, or null
// when there was nothing rankable to find. durationSec is the total
// presentation length when the manifest states it (DASH VOD does;
// see parseDashManifest) — video-latch.js needs a duration to turn a
// variant's declared bitrate into an estimated file size, and the manifest
// is a more reliable source for it than the <video> element, which reports
// NaN until it has loaded metadata.
async function fetchAndParseManifest(url, kind) {
  try {
    const res = await fetch(url, { credentials: 'include' });
    if (!res.ok) return null;
    const text = await res.text();
    return kind === 'dash' ? parseDashManifest(text, url) : parseHlsManifest(text, url);
  } catch (e) {
    console.error('[MDL] manifest fetch/parse failed for', url, ':', e);
    return null;
  }
}

async function resolveDetectedManifest(media) {
  let parsed = parsedManifestsByUrl.get(media.url);
  if (parsed === undefined) {
    parsed = await fetchAndParseManifest(media.url, media.kind);
    parsedManifestsByUrl.set(media.url, parsed);
  }
  return parsed;
}

function notifyManifestResolved(tabId, media) {
  // Resolve before notifying: the visible latch promises that the quality
  // options are ready, rather than merely that a URL ending in .m3u8/.mpd
  // happened to pass through the tab.
  void resolveDetectedManifest(media).then(() => {
    chrome.tabs.sendMessage(tabId, {
      type: 'streamManifestResolved',
      payload: { url: media.url, kind: media.kind, groupKey: media.groupKey },
    }, () => {
      // A navigation can remove the content script while the manifest is
      // resolving. That is expected; accessing lastError consumes it.
      void chrome.runtime.lastError;
    });
  });
}

// HLS master-playlist parsing: pulls every #EXT-X-STREAM-INF variant out of
// the text, plus any #EXT-X-MEDIA:TYPE=AUDIO renditions a variant's AUDIO
// group-id references. Plain line-based parsing, not a general M3U8
// library — HLS's tag format (#EXT-X-STREAM-INF:KEY=VALUE,KEY="quoted,value",...
// followed by a URI line) is simple and regular enough that this covers the
// real world without a dependency, but it's not attempting every corner of
// the spec (SUBTITLES renditions, IFRAME-only streams, and CLOSED-CAPTIONS
// are still not surfaced as their own rows here).
function parseHlsManifest(text, manifestUrl) {
  const lines = text.split(/\r?\n/);
  const variants = [];

  // #EXT-X-MEDIA:TYPE=AUDIO entries declare the split-audio renditions a
  // variant can reference by GROUP-ID — this is the piece that was missing
  // before: a video-only variant whose segments never carry sound at all,
  // with the matching audio living in a completely separate playlist. The
  // Swift side only ever receives the ONE media playlist URL this parser
  // picks below, never the master — it has no way to rediscover this
  // association on its own, so it has to be resolved here and sent along.
  // Collected in its own pass since the spec doesn't guarantee these appear
  // before the #EXT-X-STREAM-INF lines that reference them.
  const audioGroups = new Map(); // groupId -> [{ url, lang, isDefault }]
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line.startsWith('#EXT-X-MEDIA:')) continue;
    const attrs = parseAttributeList(line.slice('#EXT-X-MEDIA:'.length));
    if ((attrs['TYPE'] || '').toUpperCase() !== 'AUDIO') continue;
    const groupId = attrs['GROUP-ID'];
    const uri = attrs['URI'];
    // No URI means this rendition has no separate media of its own (rare —
    // e.g. a descriptive-video-service placeholder) — nothing to fetch.
    if (!groupId || !uri) continue;
    let resolvedUri;
    try { resolvedUri = new URL(uri, manifestUrl).href; } catch { continue; }
    if (!audioGroups.has(groupId)) audioGroups.set(groupId, []);
    audioGroups.get(groupId).push({
      url: resolvedUri,
      lang: attrs['LANGUAGE'] || null,
      isDefault: (attrs['DEFAULT'] || '').toUpperCase() === 'YES',
    });
  }

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    const attrs = parseAttributeList(line.slice('#EXT-X-STREAM-INF:'.length));
    // The variant's URI is whatever the next non-comment, non-blank line is.
    let uriLine = null;
    for (let j = i + 1; j < lines.length; j++) {
      const next = lines[j].trim();
      if (!next || next.startsWith('#')) continue;
      uriLine = next;
      break;
    }
    if (!uriLine) continue;
    let resolvedUri;
    try { resolvedUri = new URL(uriLine, manifestUrl).href; } catch { continue; }
    const bandwidth = attrs['AVERAGE-BANDWIDTH'] || attrs['BANDWIDTH'];
    const [width, height] = (attrs['RESOLUTION'] || '').split('x').map(Number);
    const codecs = attrs['CODECS'] || null;
    // Present only when this variant's video is genuinely split from its
    // audio — the common combined-stream case (segments carry both) never
    // sets AUDIO at all, and this stays null/omitted for it. Each candidate
    // is one language/rendition option within the group; the app picks one
    // according to the person's language preference, the same way it
    // already does for DASH's separate AdaptationSets — selection
    // deliberately isn't duplicated here in JS.
    const audioGroupId = attrs['AUDIO'] || null;
    const audioTracks = audioGroupId ? (audioGroups.get(audioGroupId) || null) : null;
    variants.push({
      url: resolvedUri,
      // An HLS variant playlist is its own complete, independently
      // fetchable media playlist, so this URL really does select exactly
      // this quality — the DASH side can't always say the same, hence the
      // flag rather than an assumption. See parseDashManifest.
      exactUrl: true,
      bandwidthBps: bandwidth ? parseInt(bandwidth, 10) : null,
      width: width || null,
      height: height || null,
      fps: parseFrameRate(attrs['FRAME-RATE']),
      codecs,
      codecFamily: codecFamilyLabel(codecs),
      track: 'video',
      audioTracks: audioTracks && audioTracks.length ? audioTracks : null,
    });
  }
  // No #EXT-X-STREAM-INF found — this manifest is either a plain
  // single-quality media playlist (segments directly, no variant list) or
  // something malformed. Either way there's nothing to offer as separate
  // quality rows; the caller falls back to the one opaque row it already had.
  if (!variants.length) return null;
  variants.sort(byQualityDescending);
  // No durationSec: an HLS *master* playlist carries no total-duration
  // field at all (only the per-variant media playlists do, as a sum of
  // their #EXTINF tags), and fetching every variant playlist just to total
  // up segment durations is far more network traffic than a size estimate
  // is worth. video-latch.js falls back to the <video> element's own
  // duration for these.
  return { variants, durationSec: null };
}

// Parses a comma-separated HLS attribute list (KEY=VALUE,KEY="quoted,val").
// A plain split(',') breaks the moment any quoted value itself contains a
// comma — CODECS="avc1.64001f,mp4a.40.2" is extremely common and would
// otherwise get chopped in the middle of the CODECS value. Surrounding
// quotes are stripped here rather than at each use site, so callers never
// have to remember which attributes the spec happens to quote.
function parseAttributeList(str) {
  const attrs = {};
  const re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/g;
  let m;
  while ((m = re.exec(str))) attrs[m[1]] = m[2].replace(/^"|"$/g, '');
  return attrs;
}

// HLS declares FRAME-RATE as a decimal ("29.97"); DASH declares frameRate
// as either a decimal or an exact rational ("30000/1001"). Both land here.
function parseFrameRate(raw) {
  if (!raw) return null;
  const str = String(raw).trim();
  const ratio = /^(\d+)\s*\/\s*(\d+)$/.exec(str);
  const fps = ratio ? parseInt(ratio[1], 10) / parseInt(ratio[2], 10) : parseFloat(str);
  return Number.isFinite(fps) && fps > 0 ? fps : null;
}

// Maps a codec string to the name a person would recognise. Only the first
// codec in the list matters — a variant's CODECS/codecs attribute lists
// video first, then audio ("avc1.640028,mp4a.40.2").
//
// Used to keep same-resolution rows distinguishable: a manifest offering
// both AV1 and H.264 at 1080p produces two rows that would otherwise be
// labelled identically, and the difference between them (roughly half the
// bytes for the same picture, against much narrower device support) is
// exactly the thing worth surfacing.
function codecFamilyLabel(codecs) {
  const c = (codecs || '').split(',')[0].trim().toLowerCase();
  if (!c) return null;
  if (c.startsWith('av01')) return 'AV1';
  if (c.startsWith('vp09') || c.startsWith('vp9')) return 'VP9';
  if (c.startsWith('vp08') || c.startsWith('vp8')) return 'VP8';
  if (c.startsWith('dvh') || c.startsWith('dva')) return 'Dolby Vision';
  if (c.startsWith('hvc1') || c.startsWith('hev1')) return 'HEVC';
  if (c.startsWith('avc')) return 'H.264';
  if (c.startsWith('mp4a') || c.startsWith('opus') || c.startsWith('vorbis')) return null;
  return null;
}

// Highest quality first. Resolution leads because that's what a person is
// actually choosing between; bitrate only breaks ties within a resolution
// (and stands in for it entirely on audio-only or resolution-less variants).
function byQualityDescending(a, b) {
  return (b.height || 0) - (a.height || 0) || (b.bandwidthBps || 0) - (a.bandwidthBps || 0);
}

// ─── DASH (.mpd) parsing ───────────────────────────────────────────────────
//
// Unlike HLS, DASH cannot be read off the <Representation> tags alone. Every
// piece needed to build a real quality ladder lives OUTSIDE that tag:
//
//   • mimeType / contentType are normally declared once on the parent
//     <AdaptationSet>, not repeated per Representation. Without them the
//     audio-only Representations — and the trick-play thumbnail strips that
//     ship as image/jpeg AdaptationSets — get ranked as if they were video
//     qualities, which is how you end up offering someone "128 kbps" as a
//     resolution choice.
//
//   • <BaseURL> may appear at MPD, Period, AdaptationSet AND Representation
//     level, resolving hierarchically against the manifest's own URL. This is
//     the important one: for the on-demand profile (<SegmentBase> with byte
//     ranges, which is what most VOD uses) a Representation's resolved
//     BaseURL IS one complete media file. That's a genuinely standalone
//     per-quality URL the existing plain-HTTP downloader can fetch as-is —
//     the thing this parser previously assumed DASH never has.
//
//   • <SegmentTemplate> / <SegmentList> presence is what actually decides
//     whether a Representation is that one file or several hundred segments
//     that would need assembling. Their absence is the signal, so you have
//     to look at the children to know.
//
// Hence a real structural walk rather than a flat regex. MV3 service workers
// have no DOMParser — it's a Window-only API, absent from every worker scope
// — and chrome.offscreen, the usual Chrome workaround, does not exist in
// Safari at all, so neither of the normal escape hatches is available here.
// parseXmlTree below covers the exact subset of XML that machine-generated
// MPDs use (elements, attributes, text, entities) and nothing more.
function parseDashManifest(text, manifestUrl) {
  const mpd = childrenNamed(parseXmlTree(text), 'MPD')[0];
  if (!mpd) return null;

  // Present on VOD (type="static") manifests and absent on live ones
  // (type="dynamic"), which by definition have no total length yet — so
  // this is available for exactly the case where an estimated file size is
  // a meaningful thing to show.
  const durationSec = parseIso8601Duration(mpd.attrs.mediaPresentationDuration);
  const mpdBase = resolveBaseUrl({ url: manifestUrl, explicit: false }, mpd);

  const variants = [];
  for (const period of childrenNamed(mpd, 'Period')) {
    const periodBase = resolveBaseUrl(mpdBase, period);
    for (const aset of childrenNamed(period, 'AdaptationSet')) {
      const asetBase = resolveBaseUrl(periodBase, aset);
      // Segment addressing is inherited downward, so a template declared
      // once on the AdaptationSet applies to every Representation under it.
      const asetSegmented = hasSegmentAddressing(aset);

      for (const rep of childrenNamed(aset, 'Representation')) {
        if (!rep.attrs.bandwidth) continue; // not a rankable media Representation

        const attr = (name) => rep.attrs[name] ?? aset.attrs[name];
        const track = classifyDashTrack(rep, aset);
        if (!track) continue; // subtitles, thumbnail strips, anything unrankable

        const repBase = resolveBaseUrl(asetBase, rep);
        // One file, addressable on its own, only when nothing in the chain
        // segments it AND some level actually contributed a BaseURL — with
        // no BaseURL anywhere the "resolved" base is still just the .mpd's
        // own URL, which is a manifest, not media.
        const exactUrl = !asetSegmented && !hasSegmentAddressing(rep) && repBase.explicit;
        const codecs = attr('codecs') || null;

        variants.push({
          // Non-exact rows deliberately fall back to the manifest URL: it's
          // the only thing that can be handed off usefully, and video-latch.js
          // labels those rows "auto quality" so the ladder stays honest about
          // which ones select a specific quality and which just preview it.
          url: exactUrl ? repBase.url : manifestUrl,
          exactUrl,
          representationId: rep.attrs.id || null,
          bandwidthBps: parseInt(rep.attrs.bandwidth, 10),
          // Deliberately not falling back to the AdaptationSet's
          // maxWidth/maxHeight: those are the maximum ACROSS its
          // Representations, not this one's dimensions, so borrowing them
          // would label a 360p rung as 1080p. A resolution-less variant
          // showing only its bitrate is the honest outcome.
          width: intOrNull(attr('width')),
          height: intOrNull(attr('height')),
          fps: parseFrameRate(attr('frameRate')),
          codecs,
          codecFamily: codecFamilyLabel(codecs),
          track,
        });
      }
    }
  }

  // Video is the ladder whenever there is one — see dedupeVariants for what
  // counts as a duplicate and why bitrate isn't collapsed on.
  const video = dedupeVariants(variants.filter((v) => v.track === 'video'));
  // Audio-only DASH (music/podcast services) is a real shape, and for it the
  // audio Representations aren't a distraction from the ladder — they ARE
  // the ladder. Only fall back to them when there's no video at all, so
  // normal video manifests don't grow a tail of audio rows.
  const ranked = video.length ? video : dedupeVariants(variants.filter((v) => v.track === 'audio'));
  if (!ranked.length) return null;
  if (ranked.length > DASH_MAX_VARIANTS) {
    console.log('[MDL] dash ladder trimmed from ' + ranked.length + ' to ' + DASH_MAX_VARIANTS + ' rows for ' + manifestUrl);
  }
  return { variants: ranked.slice(0, DASH_MAX_VARIANTS), durationSec };
}

const DASH_MAX_VARIANTS = 12;

// Collapses repeats and orders the ladder highest-quality-first.
//
// Representations within one AdaptationSet are switchable alternatives, so
// they're distinct by construction — the duplicates actually worth removing
// come from multi-Period manifests, where a VOD with ad breaks repeats its
// entire ladder once per Period and the same rung shows up several times.
//
// Bitrate is part of a rung's identity rather than something to collapse on:
// three Representations at one resolution and codec differing only in bitrate
// are three real choices (720p at 1.4 Mbps against 720p at 4.5 Mbps is 100 MB
// against 320 MB of the same picture size — DASH-IF's own MultiRate vector is
// exactly this shape). Keying without it silently drops the smaller options
// and leaves only the largest, which is the opposite of offering a choice.
// Sheer volume is handled by the ordering plus DASH_MAX_VARIANTS instead, so
// what gets trimmed is the bottom of the ladder rather than the middle.
function dedupeVariants(variants) {
  const byIdentity = new Map();
  for (const v of variants) {
    const key = [v.height || v.width || 'na', v.codecFamily || v.codecs || 'na', v.bandwidthBps].join('|');
    if (!byIdentity.has(key)) byIdentity.set(key, v);
  }
  return [...byIdentity.values()].sort(byQualityDescending);
}

// video / audio / null, checked in descending order of trustworthiness:
// an explicit declaration on the Representation, then the same on the
// parent AdaptationSet (where most manifests actually put it), then the
// structural tells. Returns null for anything that isn't a rankable A/V
// track — subtitles, and the image/jpeg AdaptationSets used for the
// thumbnail strip on a scrub bar.
function classifyDashTrack(rep, aset) {
  const mime = rep.attrs.mimeType || aset.attrs.mimeType || '';
  const contentType = rep.attrs.contentType || aset.attrs.contentType || '';
  if (/^video/i.test(mime) || /^video$/i.test(contentType)) return 'video';
  if (/^audio/i.test(mime) || /^audio$/i.test(contentType)) return 'audio';
  if (/^(text|image|application)/i.test(mime) || /^(text|image)$/i.test(contentType)) return null;

  // Nothing declared: infer. Only a video track has pixel dimensions, and
  // only an audio track has a sampling rate.
  if (rep.attrs.width || rep.attrs.height || aset.attrs.maxWidth || aset.attrs.maxHeight) return 'video';
  if (rep.attrs.audioSamplingRate || aset.attrs.audioSamplingRate) return 'audio';

  const codecs = (rep.attrs.codecs || aset.attrs.codecs || '').toLowerCase();
  if (/^(avc|hvc1|hev1|vp0?[89]|av01|dv[ha])/.test(codecs)) return 'video';
  if (/^(mp4a|opus|vorbis|[ae]c-3|flac|alac)/.test(codecs)) return 'audio';
  return null;
}

// Resolves this element's own <BaseURL> child, if any, against the parent's
// already-resolved base. `explicit` tracks whether any level in the chain
// actually supplied one — the difference between "this URL points at a media
// file" and "this is still just the .mpd's own address".
function resolveBaseUrl(parent, node) {
  const el = childrenNamed(node, 'BaseURL')[0];
  const raw = el ? el.text.trim() : '';
  if (!raw) return parent;
  try {
    return { url: new URL(raw, parent.url).href, explicit: true };
  } catch {
    return parent;
  }
}

function hasSegmentAddressing(node) {
  return node.children.some((c) => c.name === 'SegmentTemplate' || c.name === 'SegmentList');
}

function childrenNamed(node, name) {
  return node.children.filter((c) => c.name === name);
}

function intOrNull(raw) {
  const n = parseInt(raw, 10);
  return Number.isFinite(n) ? n : null;
}

// ISO 8601 duration ("PT1H2M3.5S"), the format DASH states every duration
// in. Years and months are accepted for completeness but are nonsense in a
// media manifest, so their approximate day counts don't matter in practice.
function parseIso8601Duration(raw) {
  if (!raw) return null;
  const m = /^-?P(?:([\d.]+)Y)?(?:([\d.]+)M)?(?:([\d.]+)W)?(?:([\d.]+)D)?(?:T(?:([\d.]+)H)?(?:([\d.]+)M)?(?:([\d.]+)S)?)?$/
    .exec(String(raw).trim());
  if (!m) return null;
  const n = (i) => (m[i] ? parseFloat(m[i]) || 0 : 0);
  const secs = n(1) * 31556952 + n(2) * 2629746 + n(3) * 604800 + n(4) * 86400
    + n(5) * 3600 + n(6) * 60 + n(7);
  return secs > 0 ? secs : null;
}

// Minimal XML element walker: builds a {name, attrs, children, text} tree.
// Not a general XML parser and not trying to be one — no DTDs, no entity
// declarations, no namespace resolution, no validation. Prefixes are
// stripped to local names so a manifest that qualifies its elements
// (<dash:Representation>) reads the same as the overwhelmingly common
// unprefixed form. Comments, CDATA, the XML declaration and doctypes are
// recognised only so they can be skipped without confusing the tag matcher.
function parseXmlTree(text) {
  const root = { name: '#root', attrs: {}, children: [], text: '' };
  const stack = [root];
  // Quoted runs are matched as units so that a '>' or '/>' inside an
  // attribute value can't be mistaken for the end of the tag — DASH's
  // media="$RepresentationID$/$Number$.m4s" templates are full of slashes.
  const tagRe = /<\?[\s\S]*?\?>|<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<![\s\S]*?>|<(\/?)([A-Za-z_][\w.:-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>/g;
  let cursor = 0;
  let m;
  while ((m = tagRe.exec(text))) {
    if (m.index > cursor) stack[stack.length - 1].text += decodeXmlEntities(text.slice(cursor, m.index));
    cursor = tagRe.lastIndex;
    if (m[2] === undefined) continue; // declaration / comment / CDATA / doctype

    const name = m[2].replace(/^[^:]*:/, '');
    if (m[1] === '/') {
      // Unwind to the matching open element rather than blindly popping, so
      // a stray or mismatched close tag can't desynchronise the whole tree.
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i].name === name) { stack.length = i; break; }
      }
      continue;
    }

    const node = { name, attrs: parseXmlAttrs(m[3] || ''), children: [], text: '' };
    stack[stack.length - 1].children.push(node);
    if (!m[4]) stack.push(node); // not self-closing — children belong to it
  }
  return root;
}

function parseXmlAttrs(str) {
  const attrs = {};
  const re = /([A-Za-z_][\w.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
  let m;
  while ((m = re.exec(str))) attrs[m[1]] = decodeXmlEntities(m[2] !== undefined ? m[2] : m[3]);
  return attrs;
}

// Only the five predefined entities plus numeric character references —
// which is all a machine-generated MPD can legally contain without
// declaring its own. &amp; matters most: query strings inside <BaseURL>
// text and SegmentTemplate URLs are escaped, and leaving them escaped
// produces URLs that 404.
function decodeXmlEntities(str) {
  if (!str.includes('&')) return str;
  return str.replace(/&(?:(lt|gt|amp|quot|apos)|#(\d+)|#[xX]([0-9a-fA-F]+));/g, (full, name, dec, hex) => {
    if (dec) return String.fromCodePoint(parseInt(dec, 10));
    if (hex) return String.fromCodePoint(parseInt(hex, 16));
    return { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" }[name];
  });
}

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0) {
      console.log('[MDL] skipped request (no tab, tabId=' + details.tabId + '):', details.url);
      return;
    }
    if (details.method !== 'GET') return;
    
    const headers = details.responseHeaders || [];
    const contentType = headers.find(h => h.name.toLowerCase() === 'content-type')?.value || '';
    const contentLength = headers.find(h => h.name.toLowerCase() === 'content-length')?.value;
    
    // Skip page navigations and obviously-not-a-file responses — we only
    // care about actual downloadable payloads (binary, text/plain raw
    // files, octet-stream, etc.), not the HTML page itself.
    if (/text\/html/i.test(contentType)) return;
    
    console.log('[MDL] tracked request tab=' + details.tabId + ' type=' + contentType + ' ' + details.url);
    
    if (!recentRequestsByTab.has(details.tabId)) recentRequestsByTab.set(details.tabId, []);
    const list = recentRequestsByTab.get(details.tabId);
    list.push({
      url: details.url,
      contentType,
      size: contentLength ? parseInt(contentLength, 10) : null,
      at: Date.now(),
    });
    while (list.length > RECENT_MAX_PER_TAB) list.shift();

    const kind = classifyMediaResponse(details.url, contentType);
    if (!kind) return;
    console.log('[MDL] detected media tab=' + details.tabId + ' kind=' + kind + ' ' + details.url);
    if (!detectedMediaByTab.has(details.tabId)) detectedMediaByTab.set(details.tabId, []);
    const mediaList = detectedMediaByTab.get(details.tabId);
    if (mediaList.some(m => m.url === details.url)) return; // already tracked
    mediaList.push({
      url: details.url,
      contentType,
      size: contentLength ? parseInt(contentLength, 10) : null,
      kind,
      groupKey: groupKeyForManifest(details.url),
      at: Date.now(),
    });
    while (mediaList.length > DETECTED_MEDIA_MAX_PER_TAB) mediaList.shift();
    notifyManifestResolved(details.tabId, mediaList[mediaList.length - 1]);
  },
  { urls: ['<all_urls>'], types: ['xmlhttprequest', 'other', 'object', 'ping', 'sub_frame'] },
  ['responseHeaders']
);

chrome.tabs.onRemoved.addListener((tabId) => {
  recentRequestsByTab.delete(tabId);
  detectedMediaByTab.delete(tabId);
});

// Detected media is scoped to "this page's current playback", not "this
// tab, ever" — a fresh navigation should show a fresh, empty list rather
// than whatever the previous page on this tab happened to be streaming.
// changeInfo.url is only present on the onUpdated event that actually
// represents a new top-level navigation (not, say, a tab title change), so
// this doesn't need the webNavigation permission the project has
// deliberately avoided taking on elsewhere (see video-latch.js).
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (changeInfo.url) detectedMediaByTab.delete(tabId);
});

// Given a blob: download that just fired on a tab, find the real request
// that most plausibly produced it — most recent first, optionally matched
// by size when Chrome already knows the blob's byte count.
function resolveBlobSource(tabId, approxSize) {
  const list = recentRequestsByTab.get(tabId);
  console.log('[MDL] resolveBlobSource tabId=' + tabId + ' approxSize=' + approxSize + ' trackedCount=' + (list?.length || 0), list);
  if (!list?.length) return null;
  
  const now = Date.now();
  const candidates = list.filter(r => now - r.at < RECENT_WINDOW_MS);
  console.log('[MDL] candidates within window:', candidates);
  if (!candidates.length) return null;
  
  if (approxSize && approxSize > 0) {
    const sizeMatch = candidates.find(r => r.size && Math.abs(r.size - approxSize) < 16);
    if (sizeMatch) return sizeMatch.url;
  }
  
  // No exact size match — fall back to the most recent real request on
  // this tab, since that's overwhelmingly likely to be the one that just
  // fed the blob that was created a moment later.
  return candidates[candidates.length - 1].url;
}

chrome.runtime.onInstalled.addListener(() => {
  createContextMenus();
  connectNativeHost();
});

chrome.runtime.onStartup.addListener(() => {
  connectNativeHost();
});

function connectNativeHost() {
  try {
    port = chrome.runtime.connectNative(NATIVE_HOST);
    port.onMessage.addListener(handleNativeMessage);
    port.onDisconnect.addListener(() => {
      console.log('Native host disconnected');
      setTimeout(connectNativeHost, 5000);
    });
  } catch (e) {
    console.error('Failed to connect to native host:', e);
  }
}

function handleNativeMessage(message) {
  console.log('Received from native:', message);
  
  // The immediate reply to a relayed request (download, getDownloads,
  // pause/resume/cancel, listYouTubeFormats) when the host couldn't reach
  // the app at all — distinct from the async downloadStarted/downloadCompleted/
  // downloadFailed pushes below, which always carry a `type`. This one
  // doesn't, which is exactly what used to make it fall through here
  // silently: nothing in this switch ever matched it.
  if (message && message.success === false && message.error === APP_NOT_RUNNING_ERROR) {
    // Launch and replay rather than prompt: the browser's copy of the
    // download is already cancelled by now, so a declined prompt lost it.
    // Matches the YouTube path, which has always launched via its URL scheme.
    openAppAndRetry();
    return;
  }

  // Any relayed reply with an explicit `success` field means the app
  // actually handled the request (true success OR a definitive error like
  // "No valid URLs"). Drop the stashed payload now so a later miss never
  // replays a download the user already saw the outcome of. The dedicated
  // `downloadStarted` clear below is dead in practice — the Swift side
  // never emits that notification — so without this, pendingRetryPayload
  // would stay stashed indefinitely after every successful relay.
  if (message && typeof message.success === 'boolean') {
    pendingRetryPayload = null;
  }
  
  switch (message.type) {
    case 'downloadStarted':
      pendingRetryPayload = null;
      showNotification('Download started', message.filename);
      break;
    case 'downloadCompleted':
      showNotification('Download completed', message.filename);
      break;
    case 'downloadFailed':
      // An auth failure sent without cookies has an obvious next step, so
      // name it instead of showing the raw error.
      if (lastRequestCookiesSkipped && /403|401|expired|forbidden|unauthorized/i.test(message.error || '')) {
        showNotification(
          'Download failed — site may need your login',
          'Open the Convoy popup and turn on "Send site cookies", then try again.'
        );
      } else {
        showNotification('Download failed', message.error);
      }
      break;
  }
}

// Messaging only reaches tabs where the content script is live, which
// excludes tabs that were already open when the extension loaded or last
// reloaded. Injecting it on demand covers those; "scripting" costs nothing
// at install time (it shows no permission warning) and dropping it made
// those tabs silently unresponsive.
async function ensureContentScript(tabId) {
  try {
    await chrome.scripting.executeScript({
      target: { tabId, frameIds: [0] },
      files: ['ContentScripts/content-script.js'],
    });
    return true;
  } catch (e) {
    // chrome://, the Web Store, a PDF viewer — pages no extension may touch.
    console.log('[MDL] cannot inject into this tab:', e?.message || e);
    return false;
  }
}

// Sends to the content script, injecting it first if the tab doesn't
// already have one. Returns undefined when the tab can't run it at all.
async function messageContentScript(tabId, message) {
  try {
    return await chrome.tabs.sendMessage(tabId, message, { frameId: 0 });
  } catch {
    if (!(await ensureContentScript(tabId))) return undefined;
    try {
      return await chrome.tabs.sendMessage(tabId, message, { frameId: 0 });
    } catch (e) {
      console.log('[MDL] content script unreachable after injection:', e?.message || e);
      return undefined;
    }
  }
}

// Only reached when the automatic launch fails; handleNativeMessage launches
// without asking. One notification, with the reason and a retry, since a cold
// launch that timed out often works on a second try.
function promptToOpenApp(reason) {
  chrome.notifications.create(OPEN_APP_NOTIFICATION_ID, {
    type: 'basic',
    iconUrl: chrome.runtime.getURL('icon48.png'),
    title: 'Couldn\u2019t open Convoy',
    message: `${reason.replace(/\.$/, "")}. Open it to continue your download.`,
    buttons: [{ title: 'Open Convoy' }],
    requireInteraction: true,
  });
}

// foreground: the user clicked an Open control, so bring the app forward.
// The automatic launch after a capture stays in the background.
function openAppAndRetry(foreground = false) {
  chrome.runtime.sendNativeMessage(NATIVE_HOST, { type: 'launchApp', payload: { foreground } }, (response) => {
    if (chrome.runtime.lastError || !response?.success) {
      promptToOpenApp(response?.error || chrome.runtime.lastError?.message || 'Unknown error');
      return;
    }
    if (pendingRetryPayload) {
      const { urls, referrer, segmentCount, headers, cookies, requestId, filename, streamMeta } = pendingRetryPayload;
      pendingRetryPayload = null;
      // The failed attempt marked this id consumed, which would make the
      // replay look like a duplicate. It never reached the app, so release it.
      sentRequestIds.delete(requestId);
      // Pass the original requestId so the dedup check in sendDownloadRequest
      // can suppress this if the port-reconnect path already delivered it.
      sendDownloadRequest(urls, referrer, segmentCount, headers, cookies, requestId, filename, streamMeta);
    }
  });
}

// The popup's Open button. Handled here rather than in the popup, which may
// close before the launch finishes.
chrome.runtime.onMessage.addListener((message) => {
  if (message?.type !== 'openConvoyApp') return false;
  openAppAndRetry(true);
  return false;
});

// The launch-failure notification's button/body click.
chrome.notifications.onButtonClicked.addListener((notificationId) => {
  if (notificationId !== OPEN_APP_NOTIFICATION_ID) return;
  chrome.notifications.clear(notificationId);
  openAppAndRetry(true);
});
chrome.notifications.onClicked.addListener((notificationId) => {
  if (notificationId !== OPEN_APP_NOTIFICATION_ID) return;
  chrome.notifications.clear(notificationId);
  openAppAndRetry(true);
});

function createContextMenus() {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: 'download-link',
      title: 'Download with Convoy',
      contexts: ['link'],
      targetUrlPatterns: ['<all_urls>']
    });
    
    chrome.contextMenus.create({
      id: 'download-image',
      title: 'Download image with Convoy',
      contexts: ['image'],
      targetUrlPatterns: ['<all_urls>']
    });
    
    chrome.contextMenus.create({
      id: 'download-media',
      title: 'Download video/audio with Convoy',
      contexts: ['video', 'audio'],
      targetUrlPatterns: ['<all_urls>']
    });
  });
}

// Messages from content scripts (e.g. the video-latch overlay button) and
// the popup — both send the same shape the native host already expects.
// For YouTube URLs we attach cookies + user-agent so the native host
// can impersonate the browser session (fixes 403 on signed streams).
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'downloadRequest') return false;
  
  const { urls, referrer, segmentCount, headers: explicitHeaders, filename,
          streamType, representationId, bandwidth, audioTracks } = message.payload || {};
  if (!urls?.length) return false;
  
  const ref = referrer || sender?.tab?.url;

  // Always go through enrichRequest so session cookies (especially
  // YouTube's .youtube.com-scoped cookies needed for googlevideo.com
  // streams) are attached. explicitHeaders (e.g. yt-dlp's per-format
  // http_headers) are passed as extraHeaders and merged on top — they
  // provide UA/Accept/Sec-Fetch but never cookies, so skipping
  // enrichRequest was the root cause of the 403→EXPIRED loop.
  enrichRequest(urls, ref, segmentCount, filename, explicitHeaders,
    { streamType, representationId, bandwidth, audioTracks },
    sender?.tab?.incognito === true);
  
  return false; // synchronous, enrichment happens via callbacks/promises
});

// The title of the tab a content script runs in, for a frame that has none
// of its own (an embedded player) and can't read its cross-origin parent.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'getTabTitle') return false;
  sendResponse({ title: sender?.tab?.title || null });
  return false;
});

// video-latch.js's 'sniff' strategy panel asks for this right as it opens,
// to merge network-detected media (HLS/DASH manifests caught by the
// onHeadersReceived listener above) alongside whatever the DOM-only
// collectSources() already found. Each entry is enriched with its parsed
// variant list (fetched/parsed lazily here, cached in
// parsedManifestsByUrl so a repeat panel-open on the same manifest is
// instant) — video-latch.js is what actually turns those into per-quality
// rows. sender.tab.id is exactly the right scope here without the content
// script needing to know or pass its own tab id — Chrome/Safari attach the
// sending tab automatically for any message that originates from a content
// script.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'getDetectedMedia') return false;
  const tabId = sender?.tab?.id;
  let media = tabId != null ? (detectedMediaByTab.get(tabId) || []) : [];

  if (message.manifestUrl) {
    // 1. Exact manifest URL from the DOM. Registered when the network never
    // saw it: a navigation to the playlist itself, or native HLS playback,
    // whose requests are type 'media' and not observed above.
    let match = media.find((m) => m.url === message.manifestUrl);
    if (!match) {
      const kind = /\.mpd(\?|$)/i.test(message.manifestUrl) ? 'dash' : 'hls';
      const groupKey = message.groupKey || groupKeyForManifest(message.manifestUrl);
      match = { url: message.manifestUrl, kind, groupKey, at: Date.now() };
      if (tabId != null) {
        if (!detectedMediaByTab.has(tabId)) detectedMediaByTab.set(tabId, []);
        detectedMediaByTab.get(tabId).push(match);
      }
      media = [...media, match];
    }
    const groupKey = message.groupKey || match.groupKey;
    media = media.filter((m) => m.groupKey === groupKey);
  } else if (message.groupKey) {
    // 2. Exact group key match (e.g. a data-mdl-group tag with no manifest)
    media = media.filter((m) => m.groupKey === message.groupKey);
  } else if (message.isSingleVideoPage) {
    // 3. Exactly one video exists on the entire page — all detected streams belong to it
  } else {
    // 4. Multi-video page with no exact match — DO NOT leak arbitrary streams across videos!
    media = [];
  }

  (async () => {
    const enriched = await Promise.all(media.map(async (m) => {
      const parsed = await resolveDetectedManifest(m);
      return { ...m, variants: parsed?.variants || null, durationSec: parsed?.durationSec ?? null };
    }));
    sendResponse({ media: enriched });
  })();
  return true; // keep the message channel open for the async response above
});



// Sent by video-latch.js when the user clicks the download button on a
// ytdlp-strategy site (YouTube today). One-shot request/response — the app
// opens (or comes to front) via the convoy:// URL scheme with the
// page URL attached, and its own AddDownloadsView takes over from there
// (fetches formats itself, shows the picker, downloads, muxes). Nothing
// else happens on the browser side; there is no format list or panel to
// render here anymore.
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== 'openYouTubeDownload') return false;

  const url = message.payload?.url;
  if (!url) {
    sendResponse({ success: false, error: 'No URL provided' });
    return false;
  }

  chrome.runtime.sendNativeMessage(NATIVE_HOST, { type: 'openYouTubeDownload', payload: { url } }, (response) => {
    if (chrome.runtime.lastError) {
      sendResponse({ success: false, error: chrome.runtime.lastError.message });
      return;
    }
    sendResponse(response);
  });
  return true; // keep the message channel open for the async response above
});

// Enriches a download request with the browser's session cookies for each
// URL, plus a realistic User-Agent and Referer. Previously only YouTube /
// googlevideo URLs got cookie forwarding — every other site (Overleaf,
// private GitHub, Notion exports, anything auth-gated) hit the server with
// no credentials at all, got a 403, and got mislabeled "link expired" by
// the engine's 403→.urlExpired path. Now every download is enriched.
//
// Cookies require the optional "cookies" permission (the popup's toggle).
// Without it the UA and Referer below still apply and the cookie stages are
// skipped entirely — chrome.cookies is undefined until the grant.
//
// Two-stage cookie gathering per URL:
//   1. chrome.cookies.getAll({url}) — cookies Chrome would send to that URL
//      (session cookies for overleaf.com, github.com, etc.). This is the
//      generic path that fixes non-YouTube auth-required downloads.
//   2. URLs on youtube.com / youtu.be / googlevideo.com additionally get
//      .youtube.com-domain cookies. YouTube's session cookies are scoped to
//      .youtube.com and DON'T match a googlevideo.com URL via getAll({url}),
//      but the googlevideo media stream needs them — so the explicit
//      domain-scoped fetch stays.
// Cookies are deduped by name (first occurrence wins) so the explicit YT
// fetch can't pile a duplicate on top of the per-URL fetch.
//
// extraHeaders: optional caller-supplied headers merged on top — used by
// the native-download interception path to carry Content-Length through
// (Content-Length is for IPCServer's Re-link size-matching only and gets
// stripped before the actual outgoing GET).
//
// isIncognito picks the cookie store of the window the download came from.
async function enrichRequest(urls, referrer, segmentCount, filename, extraHeaders, streamMeta, isIncognito) {
  // One request per host. buildEnrichedHeaders accumulates cookies across
  // every URL it is handed, and the result becomes a single Cookie header
  // sent with all of them — so a mixed-host batch ("Download Selected" on a
  // page whose video and images sit on different CDNs, or Alt+Shift+D) used
  // to hand one host's session cookies to another. Grouping first keeps each
  // host's credentials to itself.
  //
  // Single-host batches — HLS/DASH segment lists, every one-URL caller —
  // produce exactly one group and behave as before. A mixed-host batch now
  // arrives as several requests, so only the last is stashed for the
  // app-closed replay; that follows the single-slot non-goal documented on
  // pendingRetryPayload rather than widening it into a retry queue.
  for (const group of groupURLsByHost(urls)) {
    const headers = await buildEnrichedHeaders(group, referrer, extraHeaders, isIncognito);
    const cookies = headers.__cookiesDict;
    delete headers.__cookiesDict;
    sendDownloadRequest(group, referrer, segmentCount, headers, cookies, undefined, filename, streamMeta);
  }
}

// Splits a batch into per-host groups, preserving the order of the groups
// and of the URLs inside each. Unparseable URLs (blob:, malformed) have no
// host to scope cookies to and never match a lookup, so they travel
// together in one group of their own.
function groupURLsByHost(urls) {
  const groups = new Map();
  for (const u of urls) {
    let key;
    try {
      key = new URL(u).hostname.toLowerCase();
    } catch {
      key = '\u0000nohost';
    }
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(u);
  }
  return Array.from(groups.values());
}

// The incognito window's cookie store: the one whose tabs are incognito.
// Undefined when there is none or the lookup fails.
async function incognitoCookieStoreId() {
  try {
    const incognitoTabIds = new Set(
      (await chrome.tabs.query({})).filter((t) => t.incognito).map((t) => t.id)
    );
    const stores = await chrome.cookies.getAllCookieStores();
    return stores.find((s) => s.tabIds.some((id) => incognitoTabIds.has(id)))?.id;
  } catch {
    return undefined;
  }
}

// Gathers session cookies, a realistic User-Agent, and Referer for a set of
// URLs. Factored out of enrichRequest's own body on its own so a future
// second caller needing the same logic doesn't end up with a second,
// drifted copy of it — exactly the kind of bug that's bitten this project
// before.
//
// Callers must pass URLs that share a host: the cookies gathered below are
// pooled into one Cookie header for the whole set, so a mixed-host set
// would leak each host's credentials to the others. enrichRequest groups
// by host before calling in.
//
// Returns the headers dict with an extra, non-header __cookiesDict key
// carrying the {name: value} map IPCServer also wants — callers must
// delete it before treating the result as real outgoing headers.
async function buildEnrichedHeaders(urls, referrer, extraHeaders, isIncognito) {
  const headers = { ...(extraHeaders || {}) };
  const cookies = {};
  const seenCookieNames = new Set();
  const cookiePairs = [];

  // "cookies" is an optional permission the user grants from the popup, so
  // every path through here has to work without it. Ungranted means the
  // request goes out with UA and Referer but no credentials — fine for a
  // public file, a 403 for anything behind a login.
  //
  // Cookies come from the store of the window the download started in. This
  // service worker runs in the regular profile ("spanning" incognito), so
  // chrome.cookies without a storeId reads the regular jar even for an
  // incognito download; incognitoCookieStoreId finds the incognito one.
  //
  // The reason is recorded so an auth failure can say why.
  let storeId;
  if (!(await chrome.permissions.contains({ permissions: ['cookies'] }))) {
    lastRequestCookiesSkipped = 'noPermission';
  } else {
    lastRequestCookiesSkipped = null;
    if (isIncognito) storeId = await incognitoCookieStoreId();
  }
  // An incognito download never falls back to the regular store.
  const cookieURLs = lastRequestCookiesSkipped || (isIncognito && !storeId) ? [] : urls;

  try {
    for (const u of cookieURLs) {
      let host;
      try {
        host = new URL(u).hostname.toLowerCase();
      } catch {
        continue; // blob: / malformed — skip cookie lookup, never matches YT
      }

      // Stage 1: per-URL cookie jar (the generic fix for non-YouTube sites).
      // Wrapped per-URL so a single failure (cookies API rejecting blob:
      // etc.) doesn't lose cookies for the other URLs in this batch.
      try {
        const urlCookies = await chrome.cookies.getAll(storeId ? { url: u, storeId } : { url: u });
        for (const c of urlCookies) {
          if (!seenCookieNames.has(c.name)) {
            seenCookieNames.add(c.name);
            cookiePairs.push(`${c.name}=${c.value}`);
            cookies[c.name] = c.value;
          }
        }
      } catch (e) {
        console.error('[MDL] getAll({url}) failed for', u, ':', e);
      }

      // Stage 2: For regular web requests, gather cookies.
      // NOTE: yt-dlp-generated googlevideo.com URLs contain self-contained tokens
      // in their query strings (sig/lsig/pot). Adding browser session cookies
      // (like SAPISID from a logged-in Google account) creates an auth signature
      // conflict on YouTube CDN, causing intermittent 403 / EXPIRED.
      // Therefore, we do NOT attach browser session cookies to googlevideo.com URLs.
      if ((host === 'youtube.com' || host === 'www.youtube.com'
          || host === 'youtu.be' || host.endsWith('.youtube.com'))
          && !host.endsWith('.googlevideo.com')) {
        try {
          const ytCookies = await chrome.cookies.getAll(storeId ? { domain: '.youtube.com', storeId } : { domain: '.youtube.com' });
          for (const c of ytCookies) {
            if (!seenCookieNames.has(c.name)) {
              seenCookieNames.add(c.name);
              cookiePairs.push(`${c.name}=${c.value}`);
              cookies[c.name] = c.value;
            }
          }
        } catch (e) {
          console.error('[MDL] getAll .youtube.com failed:', e);
        }
      }
    }

    if (cookiePairs.length) {
      headers['Cookie'] = cookiePairs.join('; ');
    }

    // No User-Agent is set here: the app fetches over Apple's network stack
    // and fills in a Safari UA that matches it (IPCServer). A Chrome UA on
    // Apple's TLS fingerprint is a mismatch some CDNs refuse outright.
    // Referer is the page that triggered the download — many CDNs hotlink-
    // protect (403 on no/empty Referer). Skip only if caller already set one
    // in extraHeaders (e.g. explicitHeaders path where yt-dlp supplied its
    // own Referer).
    if (!headers['Referer']) {
      headers['Referer'] = referrer || '';
    }
  } catch (e) {
    console.error('[MDL] buildEnrichedHeaders failed:', e);
  }

  headers.__cookiesDict = cookies;
  return headers;
}

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const url = info.linkUrl || info.srcUrl || info.frameUrl;
  if (url) {
    // Route through enrichRequest so the page's session cookies / UA /
    // Referer are attached (see comment above enrichRequest). Previously
    // called sendDownloadRequest directly, so auth-gated right-click
    // downloads got no credentials and 403'd.
    enrichRequest([url], tab.url, undefined, undefined, undefined, undefined,
      tab?.incognito === true);
  }
});

// Intercept native browser downloads and redirect them to Convoy.
//
// onDeterminingFilename, not onCreated: Chrome holds the download until every
// listener has called suggest(), and only then shows its Save As dialog, so a
// cancel made inside that hold means the dialog never opens. From onCreated
// the cancel raced the dialog and lost whenever the browser asks where to
// save (seen in incognito): the download reached Convoy, the picker stayed up.
//
// Every path that leaves the download to the browser must call suggest(), or
// it hangs.
chrome.downloads.onDeterminingFilename.addListener((downloadItem, suggest) => {
  interceptDownload(downloadItem, suggest).catch((e) => {
    console.error('[MDL] download interception failed, leaving it to the browser:', e);
    suggest();
  });
  return true; // suggest() is called asynchronously
});

async function interceptDownload(downloadItem, suggest) {
  if (!(await isCaptureEnabled())) return suggest();

  // Avoid loops: if this download was already originated from us, skip
  if (downloadItem.byExtensionId && downloadItem.byExtensionId === chrome.runtime.id) {
    return suggest();
  }

  // History entries replayed on service-worker restart arrive as
  // 'interrupted' (the bombardment bug, when this listened to onCreated).
  // Filename determination only runs for new downloads, so this and the
  // staleness check below are defense-in-depth now.
  if (downloadItem.state !== 'in_progress') {
    console.log('[MDL] ignoring non-in_progress download (state=' + downloadItem.state + '):', downloadItem.url);
    return suggest();
  }
  
  // SECONDARY GUARD (defense-in-depth): even among 'in_progress' items,
  // reject anything with a startTime more than 30 seconds old. A genuine
  // fresh download has a startTime of essentially right now; anything older
  // is a restored/resumed history item that somehow slipped through.
  const startedAt = downloadItem.startTime ? new Date(downloadItem.startTime).getTime() : 0;
  const ageMs = Date.now() - startedAt;
  if (!startedAt || ageMs > 30000 || ageMs < 0) {
    console.log('[MDL] ignoring stale download (age=' + ageMs + 'ms):', downloadItem.url);
    return suggest();
  }
  
  const url = await fileURLOf(downloadItem);
  const referrer = downloadItem.referrer || undefined;
  
  // blob:/data: URLs only exist in the originating tab's JS memory — not a
  // real network resource. Resolve it back to the real request that
  // actually produced those bytes (see resolveBlobSource above) instead of
  // giving up on it.
  //
  // Note: chrome.downloads.DownloadItem has no tabId field at all (a wrong
  // assumption in the first version of this code) — the Downloads API just
  // doesn't expose the originating tab. The active tab at the moment the
  // download fires is the next best thing, and is correct in practice since
  // this fires essentially synchronously after the user's click.
  if (url.startsWith('blob:') || url.startsWith('data:')) {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const tabId = tabs[0]?.id;
      const realUrl = tabId != null
        ? resolveBlobSource(tabId, downloadItem.fileSize > 0 ? downloadItem.fileSize : null)
        : null;
      
      if (!realUrl) {
        console.log('[MDL] blob download with no resolvable source, letting Chrome handle it:', url);
        suggest();
        return;
      }
      console.log('[MDL] resolved blob download to real source:', realUrl);
      chrome.downloads.cancel(downloadItem.id, () => {
        // Erase, not just cancel — see the erase() call below for why this
        // matters (leaving a cancelled entry in Chrome's history is what
        // caused the original bombardment-on-restart bug in the first
        // place).
        chrome.downloads.erase({ id: downloadItem.id });
        enrichRequest([realUrl], referrer, undefined, undefined, undefined, undefined,
          downloadItem.incognito === true);
      });
    });
    return;
  }
  
  // Cancel the browser's download and forward to our native host. Include
  // Content-Length built from downloadItem.fileSize — Chrome exposes the
  // real byte size directly on the download item itself, no need to
  // inspect response headers for it. Without this, IPCServer's Re-link
  // matching (matchFreshURL) had nothing to check a size against on this
  // path at all: every download triggered by a direct click (as opposed to
  // the extension's own link-capture flow) went through here with no
  // headers sent whatsoever, so the mandatory size-match safety check
  // could never pass — Re-link silently failed every time regardless of
  // how good the candidate-matching logic was.
  const headers = downloadItem.fileSize > 0 ? { 'Content-Length': String(downloadItem.fileSize) } : undefined;
  chrome.downloads.cancel(downloadItem.id, () => {
    // Erase the cancelled entry from Chrome's download history, not just
    // cancel it. cancel() alone leaves an interrupted/USER_CANCELED record
    // sitting in Chrome's persistent history forever — and Chrome's own
    // download subsystem replays these interrupted entries as onCreated
    // events on every subsequent service-worker restart. Every hand-off
    // this extension makes would leave one of these ghost entries behind —
    // an ever-growing backlog that Chrome replays on every launch, which
    // is exactly what caused the bombardment bug (the state and staleness
    // checks above now block them, but erase prevents the list from
    // growing in the first place). erase() removes the history record
    // entirely — not the file on disk, just Chrome's memory of ever
    // attempting it — so there's nothing left to replay next time.
    chrome.downloads.erase({ id: downloadItem.id });
    // If cancellation fails, still attempt to forward. Pass Content-Length
    // through as extraHeaders (4th positional arg to enrichRequest) — it's
    // carried into the headers dict that enrichRequest builds, but
    // enrichRequest's per-URL cookie gathering still happens on top. The
    // Content-Length itself is for IPCServer's Re-link size-matching only
    // (stripped before the outgoing GET) so injecting cookies/UA around it
    // is safe and doesn't corrupt the size check.
    enrichRequest([url], referrer, undefined, undefined, headers, undefined,
      downloadItem.incognito === true);
  });
}

// Where the file came from. Chrome's `url` is the first entry of the
// download's URL chain, and when a page sent the browser on by itself (a
// Refresh header, meta refresh or script, as "Thanks, your download will
// start" pages do) that entry is the page. `finalUrl` is the file.
//
// Only then: after plain HTTP redirects `url` is the stable link and
// `finalUrl` often a signed address that expires, while the app re-follows
// `url` whenever it restarts.
async function fileURLOf(downloadItem) {
  const { url, finalUrl, referrer } = downloadItem;
  if (!finalUrl || finalUrl === url) return url;
  const withoutFragment = (u) => (u || '').split('#')[0];
  const start = withoutFragment(url);
  let isPage = start === withoutFragment(referrer);
  if (!isPage) {
    try {
      isPage = (await chrome.tabs.query({})).some((t) => withoutFragment(t.url) === start);
    } catch (e) {
      console.error('[MDL] tab lookup failed:', e);
    }
  }
  if (!isPage) return url;
  console.log('[MDL] download started at a page, forwarding the file it led to:', url, '->', finalUrl);
  return finalUrl;
}

chrome.commands.onCommand.addListener(async (command) => {
  if (command !== 'download-with-convoy') return;
  if (!(await isCaptureEnabled())) return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) return;
  // The content script's own scanPageMedia, rather than an injected copy of
  // it: same DOM query, one implementation.
  const response = await messageContentScript(tab.id, { type: 'getPageMedia' });
  if (response?.urls?.length) enrichRequest(response.urls, tab.url, undefined, undefined, undefined, undefined,
    tab.incognito === true);
});

// requestId is passed through by both retry paths (port-reconnect setTimeout
// and openAppAndRetry) so they share the same ID as the original call.
// A fresh call from a user action always generates a new ID here.
function sendDownloadRequest(urls, referrer, segmentCount, headers, cookies, requestId, filename, streamMeta) {
  const id = requestId || crypto.randomUUID();

  if (!port) {
    connectNativeHost();
    // Thread the same id through the retry so it can be deduped below
    // if the openAppAndRetry path fires before this setTimeout does.
    setTimeout(() => sendDownloadRequest(urls, referrer, segmentCount, headers, cookies, id, filename, streamMeta), 100);
    return;
  }

  // Both retry paths converge here. Whichever arrives first marks the ID
  // consumed; the second is a no-op — the native host never sees it.
  // Consumed means posted, not accepted — see openAppAndRetry, which
  // releases the ID when a post came back "app not running".
  if (sentRequestIds.has(id)) {
    console.log('[MDL] suppressing duplicate send, requestId already delivered:', id);
    return;
  }
  sentRequestIds.add(id);
  setTimeout(() => sentRequestIds.delete(id), 30_000);

  const payload = {
    urls,
    referrer,
    segmentCount: segmentCount || 8,
  };
  if (filename) {
    payload.filename = filename;
  }

  // HLS/DASH stream routing — passed through from video-latch.js via the
  // downloadRequest message. Without these the app treats the manifest URL
  // as a plain file and downloads just the 3 KB text, not the video.
  if (streamMeta?.streamType) {
    payload.streamType = streamMeta.streamType;
    if (streamMeta.representationId) payload.representationId = streamMeta.representationId;
    if (streamMeta.bandwidth)        payload.bandwidth = streamMeta.bandwidth;
    // HLS split-audio: the candidate list from this variant's AUDIO group
    // (see parseHlsManifest) — absent for combined streams and for DASH,
    // which resolves its own audio via AdaptationSets on the app side
    // instead. The app picks one candidate per the person's language
    // preference and fetches it as a second track, same pipeline as DASH's
    // video+audio merge.
    if (streamMeta.audioTracks?.length) payload.audioTracks = streamMeta.audioTracks;
  }
  
  if (headers && Object.keys(headers).length) {
    payload.headers = headers;
  }
  
  if (cookies && Object.keys(cookies).length) {
    payload.cookies = cookies;
  }
  
  // Remembered so this exact request can be retried automatically if the
  // host comes back with "app not running" and the user then chooses to
  // open it from the prompt (see handleNativeMessage/openAppAndRetry).
  // requestId is stored so openAppAndRetry can pass it back through
  // sendDownloadRequest and the dedup check above will suppress it if
  // this port.postMessage already reached the app successfully.
  //
  // filename belongs here as much as anything else does. It used to be left
  // out, so a download that had to wait for the app to launch arrived with no
  // name at all and the app fell back to guessing from the URL - the whole
  // per-item title the content script had just worked out was discarded on
  // the one path where the user is least likely to have the app already
  // running: their first download of the session.
  pendingRetryPayload = { urls, referrer, segmentCount, headers, cookies, requestId: id, filename, streamMeta };
  
  port.postMessage({
    type: 'downloadRequest',
    payload,
  });
}


function showNotification(title, message) {
  chrome.notifications.create({
    type: 'basic',
    iconUrl: chrome.runtime.getURL('icon48.png'),
    title: `Convoy: ${title}`,
    message
  });
}
