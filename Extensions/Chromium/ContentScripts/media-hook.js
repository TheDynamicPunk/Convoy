// media-hook.js — Runs in the page's MAIN world at document_start.
// Observes manifest fetches (PerformanceObserver), intercepts XHR, MediaSource creation (URL.createObjectURL),
// and HTMLMediaElement src assignments to deterministically associate each <video> element
// with its specific HLS/DASH stream group or a proven direct-file source.
(function () {
  'use strict';

  // Avoid running more than once if injected via multiple paths
  if (window.__mdl_media_hook_installed__) return;
  window.__mdl_media_hook_installed__ = true;

  // Derives the CDN directory group key matching groupKeyForManifest in background.js
  function groupKeyForManifest(url) {
    try {
      const u = new URL(url, location.href);
      const dir = u.pathname.slice(0, u.pathname.lastIndexOf('/') + 1);
      return u.origin + dir;
    } catch {
      return url;
    }
  }

  function isManifestUrl(url) {
    if (!url || typeof url !== 'string') return false;
    return /\.m3u8(\?|$)/i.test(url) || /\.mpd(\?|$)/i.test(url);
  }

  // Rolling buffer of recent manifest requests
  const recentManifests = [];
  const MAX_MANIFESTS = 40;

  // First manifest seen per CDN directory, kept separately from the rolling
  // buffer above. A feed can preload a few dozen videos, each adding a master
  // plus its variant playlists, and the buffer would evict an early card's
  // master before that card ever starts playing. One entry per directory is
  // all the segment-to-video matching below needs, and the first one seen is
  // the master (players load it before any variant).
  const manifestByGroup = new Map(); // groupKey -> { url, groupKey, at }
  const MAX_MANIFEST_GROUPS = 200;

  function recordManifest(rawUrl) {
    if (!isManifestUrl(rawUrl)) return null;
    let fullUrl;
    try {
      fullUrl = new URL(rawUrl, location.href).href;
    } catch {
      fullUrl = rawUrl;
    }
    const groupKey = groupKeyForManifest(fullUrl);
    const entry = { url: fullUrl, groupKey, at: Date.now() };
    recentManifests.push(entry);
    if (recentManifests.length > MAX_MANIFESTS) recentManifests.shift();
    if (!manifestByGroup.has(groupKey)) {
      manifestByGroup.set(groupKey, entry);
      if (manifestByGroup.size > MAX_MANIFEST_GROUPS) {
        manifestByGroup.delete(manifestByGroup.keys().next().value);
      }
    }

    // If there is strictly ONLY ONE video on the entire page (e.g. dedicated watch
    // page or single modal player), this manifest can safely be associated with it.
    // On multi-video pages (feeds), NEVER guess across videos.
    try {
      const allVideos = document.querySelectorAll('video');
      if (allVideos.length === 1) {
        tagVideo(allVideos[0], groupKey, fullUrl);
      }
    } catch {}

    return entry;
  }

  function tagVideo(video, groupKey, manifestUrl) {
    if (!video || !groupKey) return;
    if (video.getAttribute('data-mdl-group') === groupKey) return; // already set

    video.setAttribute('data-mdl-group', groupKey);
    if (manifestUrl) {
      video.setAttribute('data-mdl-manifest', manifestUrl);
    }

    try {
      window.dispatchEvent(new CustomEvent('__mdl_video_associated__', {
        detail: { groupKey, manifestUrl }
      }));
    } catch {}
  }

  // Deterministically extracts a manifest URL from a video element, its shadow host
  // (e.g. Reddit's <shreddit-player src="...">, Mux, Vidstack), or its parent containers.
  function getManifestFromElement(video) {
    if (!video) return null;
    const vSrc = video.getAttribute?.('src');
    if (isManifestUrl(vSrc)) return vSrc;
    const vDataSrc = video.getAttribute?.('data-src');
    if (isManifestUrl(vDataSrc)) return vDataSrc;

    // Check shadow host (Web Components)
    let node = video;
    while (node) {
      const host = node.getRootNode?.()?.host;
      if (host) {
        const hSrc = host.getAttribute?.('src') || host.getAttribute?.('data-src') || host.getAttribute?.('stream-url');
        if (isManifestUrl(hSrc)) return hSrc;
        node = host;
      } else {
        break;
      }
    }

    // Check light-DOM parent container
    let parent = video.parentElement;
    while (parent && parent !== document.body && parent !== document.documentElement) {
      const pSrc = parent.getAttribute?.('src') || parent.getAttribute?.('data-src') || parent.getAttribute?.('data-manifest-url');
      if (isManifestUrl(pSrc)) return pSrc;
      parent = parent.parentElement;
    }

    return null;
  }

  // -- Which <video> is a stream's data actually going into? ----------------
  // On a page with several videos (a feed or grid) nothing on the element says
  // which manifest it plays: its src is an opaque blob: URL. But the bytes can
  // be followed. A segment is fetched into an ArrayBuffer, the player hands
  // that buffer to a SourceBuffer, the SourceBuffer belongs to a MediaSource,
  // and that MediaSource was wrapped in the blob: URL assigned to one specific
  // <video>. Each hop is an object identity, so there is no timing or
  // proximity guessing anywhere in it.
  //
  // Players that move segments through a worker, or re-wrap them (HLS .ts into
  // fMP4), append a different object, so identity alone is not enough. Their
  // bytes still prove where they came from: see sourceOfAppendedBytes, which
  // matches content, not objects. Either way the claim rests on evidence that
  // these bytes derive from that source. No timing, order, position, length or
  // site markup is ever used to guess, and when the evidence is missing or
  // points at two sources the video is simply left untagged.
  const bufferSource = new WeakMap();        // ArrayBuffer -> URL it was fetched from
  const blobSource = new WeakMap();          // Blob -> URL it was fetched from
  const sourceBufferOwner = new WeakMap();   // SourceBuffer -> MediaSource
  const mediaSourceVideo = new WeakMap();    // MediaSource -> <video>
  const blobUrlToMediaSource = new Map();    // blob: URL -> MediaSource, until assigned or revoked
  const blobUrlToDirectSource = new Map();   // blob: URL -> direct file URL, until assigned or revoked
  // A blob URL is normally assigned to a <video> or revoked straight after it
  // is made. This only bounds the entries for a player that does neither, so
  // they cannot pile up (each one keeps a whole MediaSource alive).
  const MAX_PENDING_BLOB_URLS = 50;

  // Videos whose current source has been proven (see attributeAppendedData),
  // so later appends to them are not examined again. Cleared with the tag.
  const provenVideos = new WeakSet();
  // Direct-file URLs seen feeding each video's current source (see
  // tagVideoDirectSource).
  const directUrlsByVideo = new WeakMap();

  // Called as a blob: URL is assigned to a media element.
  function noteMediaSource(video, value) {
    if (typeof value !== 'string' || !value.startsWith('blob:')) return;
    const mediaSource = blobUrlToMediaSource.get(value);
    if (mediaSource) {
      blobUrlToMediaSource.delete(value);
      mediaSourceVideo.set(mediaSource, video);
      return;
    }
    const directUrl = blobUrlToDirectSource.get(value);
    if (!directUrl) return;
    blobUrlToDirectSource.delete(value);
    tagVideoDirectSource(video, directUrl);
  }

  function clearAssociation(video) {
    video.removeAttribute('data-mdl-group');
    video.removeAttribute('data-mdl-manifest');
    video.removeAttribute('data-mdl-direct-url');
    provenVideos.delete(video);
    directUrlsByVideo.delete(video);
    provScans.delete(video);
  }

  // A tag describes the source the element had when it was made. Players reuse
  // one <video> across items, so a new source must not inherit the old tag:
  // a stale one would download the wrong video with nothing to show it.
  function resetAssociation(video, value) {
    if (typeof value !== 'string' || video.getAttribute('src') === value) return;
    clearAssociation(video);
  }

  // The recorded manifest whose directory holds this segment. Longest
  // directory wins. A manifest at the root of an origin claims every file on
  // it, which says nothing about which video a segment belongs to, so those
  // are never matched.
  function manifestForSegment(segmentUrl) {
    let full;
    try { full = new URL(segmentUrl, location.href).href; } catch { return null; }
    let best = null;
    for (const entry of manifestByGroup.values()) {
      if (!full.startsWith(entry.groupKey)) continue;
      if (!best || entry.groupKey.length > best.groupKey.length) best = entry;
    }
    if (!best) return null;
    try { if (new URL(best.groupKey).pathname === '/') return null; } catch { return null; }
    return best;
  }

  // A URL that was actually fetched into the exact ArrayBuffer appended to a
  // video's SourceBuffer is a much better signal than a DOM selector or a
  // site-specific state object.  Still, a streaming player can append many
  // segment files; only promote conventional, complete media-file URLs, and
  // reject the common segment naming schemes.  HLS/DASH stays on the manifest
  // path above, which is the only reliable way to download a segmented stream.
  function isLikelyDirectMediaFile(url) {
    try {
      const path = new URL(url, location.href).pathname.toLowerCase();
      if (!/\.(mp4|m4v|webm|mov|ogv|ogg)$/.test(path)) return false;
      return !/(?:^|[\/_-])(init|segment|chunk|fragment|part)[\/_-]?\d*(?:\.|$)/i.test(path);
    } catch {
      return false;
    }
  }

  function tagVideoDirectSource(video, rawUrl) {
    if (!video || !isLikelyDirectMediaFile(rawUrl)) return;
    let url;
    try { url = new URL(rawUrl, location.href).href; } catch { return; }
    let seen = directUrlsByVideo.get(video);
    if (!seen) directUrlsByVideo.set(video, seen = new Set());
    seen.add(url);
    // One file feeding the player is proof. Two different files are not: a
    // player given separate video and audio files, or a segmented stream whose
    // segments are named like files, would otherwise leave the tag on whichever
    // arrived last, and the download would be one segment or one track. Which
    // of them is "the video" would be a guess, so no claim is made.
    if (seen.size > 1) {
      video.removeAttribute('data-mdl-direct-url');
      return;
    }
    if (video.getAttribute('data-mdl-direct-url') === url) return;
    video.setAttribute('data-mdl-direct-url', url);
    try {
      window.dispatchEvent(new CustomEvent('__mdl_video_associated__', {
        detail: { directUrl: url }
      }));
    } catch {}
  }

  // -- Proving where appended bytes came from, by content --------------------
  // A player may fetch a segment on the main thread but append something that
  // is not the same object: it handed the buffer to a worker, or re-wrapped the
  // coded media (HLS .ts into fMP4). The coded bytes inside survive that. So a
  // few short, high-entropy windows are sampled from every fetched segment and
  // remembered with the URL; when bytes are appended to a SourceBuffer, they are
  // searched for those windows. Finding several windows from one source is
  // proof the data derives from it. Content-based, so it does not depend on any
  // player library, container, site or URL scheme.
  //
  // Conservative on purpose: a window needs variety (no runs or padding), one
  // seen in two different URLs is discarded, at least PROV_MIN_HITS windows
  // must agree, and two competing sources means no answer at all.
  const PROV_WINDOW = 24;               // bytes per window
  const PROV_WINDOWS_PER_SEGMENT = 12;
  const PROV_MIN_BYTES = 8192;          // smaller bodies are headers/init data
  const PROV_MAX_BYTES = 40 * 1024 * 1024;
  const PROV_MAX_SCAN_BYTES = 1500000;  // per appended chunk
  const PROV_MAX_WINDOWS = 6000;
  const PROV_MIN_HITS = 2;
  // Content that can never match (decrypted by the player, or re-encoded) would
  // otherwise be scanned on every append. Give each source a fixed budget.
  const PROV_MAX_SCANS_PER_SOURCE = 30;
  const provScans = new WeakMap();      // video -> scans spent on its current source
  let provWindows = new Map();          // window (hex) -> URL, or null if two URLs had it
  let provPrefilter = null;             // 3-byte prefix lookup so scanning stays cheap

  function provPrefix(u8, i) {
    return (u8[i] * 31 + u8[i + 1]) * 31 + u8[i + 2];
  }

  // Hex digits per byte value. Building keys is the hot path once many
  // segments are indexed, so no per-byte toString(16) allocation.
  const PROV_HEX = [];
  for (let i = 0; i < 256; i++) PROV_HEX[i] = (i + 256).toString(16).slice(1);

  function provHex(u8, offset) {
    let s = '';
    for (let i = 0; i < PROV_WINDOW; i++) s += PROV_HEX[u8[offset + i]];
    return s;
  }

  function provHasVariety(u8, offset) {
    const distinct = new Set();
    for (let i = 0; i < PROV_WINDOW; i++) distinct.add(u8[offset + i]);
    return distinct.size >= 10;
  }

  // Called with every fetched ArrayBuffer. Cheap: a dozen windows per segment.
  function indexSegmentBytes(buffer, url) {
    if (!(buffer instanceof ArrayBuffer) || typeof url !== 'string' || !url) return;
    const n = buffer.byteLength;
    if (n < PROV_MIN_BYTES || n > PROV_MAX_BYTES) return;
    const u8 = new Uint8Array(buffer);
    if (!provPrefilter) provPrefilter = new Uint8Array(1 << 18);
    if (provWindows.size > PROV_MAX_WINDOWS) {
      provWindows = new Map();
      provPrefilter.fill(0);
    }
    // The middle of the body, away from headers, which look alike across
    // segments and across videos.
    const lo = Math.floor(n * 0.2);
    const hi = n - PROV_WINDOW - 64;
    for (let k = 0; k < PROV_WINDOWS_PER_SEGMENT; k++) {
      let offset = lo + Math.floor((hi - lo) * (k / (PROV_WINDOWS_PER_SEGMENT - 1)));
      for (let tries = 0; tries < 8 && offset < hi && !provHasVariety(u8, offset); tries++) offset += 7;
      if (offset >= hi || !provHasVariety(u8, offset)) continue;
      const key = provHex(u8, offset);
      const known = provWindows.get(key);
      if (known === undefined) provWindows.set(key, url);
      else if (known !== url) provWindows.set(key, null);
      provPrefilter[provPrefix(u8, offset)] = 1;
    }
  }

  // The one source whose windows turn up in these appended bytes, or null.
  // Sources are compared per manifest group, so every segment of one stream
  // counts toward the same source.
  function sourceOfAppendedBytes(view) {
    if (!provPrefilter || view.length < PROV_MIN_BYTES) return null;
    const end = Math.min(view.length - PROV_WINDOW, PROV_MAX_SCAN_BYTES);
    const hits = new Map(); // owner -> { count, url }
    for (let i = 0; i < end; i++) {
      if (!provPrefilter[provPrefix(view, i)]) continue;
      const url = provWindows.get(provHex(view, i));
      if (!url) continue;
      const manifest = manifestForSegment(url);
      const owner = manifest ? manifest.groupKey : url;
      const entry = hits.get(owner);
      if (entry) entry.count++;
      else hits.set(owner, { count: 1, url });
    }
    let winner = null;
    for (const entry of hits.values()) {
      if (entry.count < PROV_MIN_HITS) continue;
      if (winner) return null; // two sources both have proof: ambiguous
      winner = entry;
    }
    return winner ? winner.url : null;
  }

  function attributeAppendedData(sourceBuffer, data) {
    const mediaSource = sourceBufferOwner.get(sourceBuffer);
    const video = mediaSource && mediaSourceVideo.get(mediaSource);
    if (!video || provenVideos.has(video)) return;
    const isView = ArrayBuffer.isView(data);
    const buffer = isView ? data.buffer : data;
    // 1. Same object that was fetched: free to check.
    // 2. Otherwise the same bytes, wherever they were copied or re-wrapped.
    let url = buffer && bufferSource.get(buffer);
    if (!url) {
      const view = isView ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength) : new Uint8Array(data);
      if (view.length >= PROV_MIN_BYTES) {
        const spent = provScans.get(video) || 0;
        if (spent >= PROV_MAX_SCANS_PER_SOURCE) return;
        provScans.set(video, spent + 1);
        url = sourceOfAppendedBytes(view);
      }
    }
    if (!url) return;
    const manifest = manifestForSegment(url);
    if (manifest) {
      tagVideo(video, manifest.groupKey, manifest.url);
      provenVideos.add(video);
    } else {
      // Not examined as proven: a second, different file would withdraw it.
      tagVideoDirectSource(video, url);
    }
  }

  function handleMediaSrc(video, srcVal) {
    if (!video || typeof srcVal !== 'string') return;

    // 1. Direct manifest URL assigned to video element
    if (isManifestUrl(srcVal)) {
      const groupKey = groupKeyForManifest(srcVal);
      tagVideo(video, groupKey, srcVal);
      return;
    }

    // 2. Deterministic manifest discovery on the element, its shadow host, or containers
    const manifestUrl = getManifestFromElement(video);
    if (manifestUrl) {
      const groupKey = groupKeyForManifest(manifestUrl);
      tagVideo(video, groupKey, manifestUrl);
      return;
    }

    // 3. Single video on page fallback
    try {
      const allVideos = document.querySelectorAll('video');
      if (allVideos.length === 1 && recentManifests.length) {
        const latest = recentManifests[recentManifests.length - 1];
        tagVideo(video, latest.groupKey, latest.url);
      }
    } catch {}
  }

  // ── 1. Intercept URL.createObjectURL ──────────────────────────────────────
  if (typeof URL !== 'undefined' && URL.createObjectURL) {
    const origCreateObjectURL = URL.createObjectURL;
    URL.createObjectURL = function (obj) {
      const blobUrl = origCreateObjectURL.apply(this, arguments);
      try {
        if (typeof MediaSource !== 'undefined' && obj instanceof MediaSource) {
          blobUrlToMediaSource.set(blobUrl, obj);
          if (blobUrlToMediaSource.size > MAX_PENDING_BLOB_URLS) {
            blobUrlToMediaSource.delete(blobUrlToMediaSource.keys().next().value);
          }
        } else if (typeof Blob !== 'undefined' && obj instanceof Blob) {
          const directUrl = blobSource.get(obj);
          if (directUrl && isLikelyDirectMediaFile(directUrl)) {
            blobUrlToDirectSource.set(blobUrl, directUrl);
            if (blobUrlToDirectSource.size > MAX_PENDING_BLOB_URLS) {
              blobUrlToDirectSource.delete(blobUrlToDirectSource.keys().next().value);
            }
          }
        }
      } catch {}
      return blobUrl;
    };
  }


  // ── 2. Intercept HTMLMediaElement.prototype.src ─────────────────────────────
  if (typeof HTMLMediaElement !== 'undefined' && HTMLMediaElement.prototype) {
    const proto = HTMLMediaElement.prototype;
    const origSrcDesc = Object.getOwnPropertyDescriptor(proto, 'src');
    if (origSrcDesc && origSrcDesc.set && origSrcDesc.get) {
      Object.defineProperty(proto, 'src', {
        configurable: true,
        enumerable: true,
        get() {
          return origSrcDesc.get.call(this);
        },
        set(val) {
          try {
            resetAssociation(this, val);
            noteMediaSource(this, val);
            handleMediaSrc(this, val);
          } catch {}
          return origSrcDesc.set.call(this, val);
        }
      });
    }

    const origSrcObjDesc = Object.getOwnPropertyDescriptor(proto, 'srcObject');
    if (origSrcObjDesc && origSrcObjDesc.set && origSrcObjDesc.get) {
      Object.defineProperty(proto, 'srcObject', {
        configurable: true,
        enumerable: true,
        get() {
          return origSrcObjDesc.get.call(this);
        },
        set(val) {
          try {
            if (typeof MediaSource !== 'undefined' && val instanceof MediaSource) {
              clearAssociation(this);
              mediaSourceVideo.set(val, this);
              // No URL to inspect on a MediaSource itself, so this can't be
              // resolved deterministically the way handleMediaSrc's other
              // paths are. Match its tier-3 fallback instead: only attribute
              // when there's exactly one video on the page, using the most
              // recently observed manifest — never guess across videos.
              const allVideos = document.querySelectorAll('video');
              if (allVideos.length === 1 && recentManifests.length) {
                const latest = recentManifests[recentManifests.length - 1];
                tagVideo(this, latest.groupKey, latest.url);
              }
            }
          } catch {}
          return origSrcObjDesc.set.call(this, val);
        }
      });
    }
  }

  // ── 3. Intercept Element.prototype.setAttribute for 'src' ───────────────────
  if (typeof Element !== 'undefined' && Element.prototype.setAttribute) {
    const origSetAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
      try {
        if (this instanceof HTMLMediaElement && typeof name === 'string' && name.toLowerCase() === 'src') {
          resetAssociation(this, value);
          noteMediaSource(this, value);
          handleMediaSrc(this, value);
        }
      } catch {}
      return origSetAttribute.apply(this, arguments);
    };
  }

  // ── 4. Observe fetch() manifest requests ────────────────────────────────────
  // Deliberately NOT a wrapper around window.fetch. This script runs in the
  // fetch the page makes, and Chrome then files the page's own failures (blocked
  // analytics calls, Cloudflare's data: probe, preload warnings) in this
  // extension's Errors list. A PerformanceObserver is told about each completed
  // fetch afterwards and never sits in the page's call stack. The manifest is
  // recorded when its response finishes rather than when it is requested, which
  // is still before any of its segments can be fetched or appended.
  if (typeof PerformanceObserver === 'function') {
    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.initiatorType !== 'fetch') continue;
          try { recordManifest(entry.name); } catch {}
        }
      }).observe({ type: 'resource', buffered: true });
    } catch {}
  }

  // ── 5. Intercept XMLHttpRequest.prototype.open ─────────────────────────────
  if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype.open) {
    const origOpen = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        if (url) this.__mdlUrl = String(url);
        if (url && typeof url === 'string' && isManifestUrl(url)) {
          recordManifest(url);
        }
      } catch {}
      return origOpen.apply(this, arguments);
    };
  }

  // ── 6. Listen for DOM media load events as backup ───────────────────────────
  // Use composedPath() to pierce shadow DOM — e.target on a composed event from
  // inside a shadow root is the shadow host, not the <video>, when the listener
  // is on window. composedPath()[0] is always the actual originating element.
  window.addEventListener('loadstart', (e) => {
    const video = e.composedPath ? e.composedPath().find((el) => el instanceof HTMLVideoElement) : e.target;
    if (video instanceof HTMLVideoElement) {
      try {
        if (video.src) handleMediaSrc(video, video.src);
        else if (video.currentSrc) handleMediaSrc(video, video.currentSrc);
      } catch {}
    }
  }, true);

  window.addEventListener('playing', (e) => {
    const video = e.composedPath ? e.composedPath().find((el) => el instanceof HTMLVideoElement) : e.target;
    if (video instanceof HTMLVideoElement) {
      try {
        if (!video.getAttribute('data-mdl-group')) {
          if (video.src) handleMediaSrc(video, video.src);
          else if (video.currentSrc) handleMediaSrc(video, video.currentSrc);
        }
      } catch {}
    }
  }, true);

  // -- 7. Follow segment bytes into the <video> that plays them --------------
  // Remember where each fetched ArrayBuffer came from, then look at what is
  // appended to a SourceBuffer. See the comment above noteMediaSource.
  if (typeof Response !== 'undefined' && Response.prototype.arrayBuffer) {
    const origArrayBuffer = Response.prototype.arrayBuffer;
    Response.prototype.arrayBuffer = function () {
      const url = this.url;
      const promise = origArrayBuffer.apply(this, arguments);
      if (!url) return promise;
      return promise.then((buffer) => {
        try { bufferSource.set(buffer, url); indexSegmentBytes(buffer, url); } catch {}
        return buffer;
      });
    };
  }

  // Some players fetch one complete file as Response.blob(), then assign its
  // object URL directly to <video> rather than using MediaSource. Preserve
  // that object identity too, so this direct-file path is as generic as the
  // SourceBuffer path above.
  if (typeof Response !== 'undefined' && Response.prototype.blob) {
    const origBlob = Response.prototype.blob;
    Response.prototype.blob = function () {
      const url = this.url;
      const promise = origBlob.apply(this, arguments);
      if (!url) return promise;
      return promise.then((blob) => {
        try { blobSource.set(blob, url); } catch {}
        return blob;
      });
    };
  }

  if (typeof XMLHttpRequest !== 'undefined' && XMLHttpRequest.prototype.send) {
    const origSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
      try {
        if (this.responseType === 'arraybuffer') {
          this.addEventListener('load', () => {
            try {
              if (this.response instanceof ArrayBuffer) {
                const url = this.__mdlUrl || this.responseURL;
                bufferSource.set(this.response, url);
                indexSegmentBytes(this.response, url);
              }
            } catch {}
          });
        }
      } catch {}
      return origSend.apply(this, arguments);
    };
  }

  if (typeof MediaSource !== 'undefined' && MediaSource.prototype.addSourceBuffer) {
    const origAddSourceBuffer = MediaSource.prototype.addSourceBuffer;
    MediaSource.prototype.addSourceBuffer = function () {
      const sourceBuffer = origAddSourceBuffer.apply(this, arguments);
      try { sourceBufferOwner.set(sourceBuffer, this); } catch {}
      return sourceBuffer;
    };
  }

  if (typeof SourceBuffer !== 'undefined' && SourceBuffer.prototype.appendBuffer) {
    const origAppendBuffer = SourceBuffer.prototype.appendBuffer;
    SourceBuffer.prototype.appendBuffer = function (data) {
      try { attributeAppendedData(this, data); } catch {}
      return origAppendBuffer.apply(this, arguments);
    };
  }

  if (typeof URL !== 'undefined' && URL.revokeObjectURL) {
    const origRevokeObjectURL = URL.revokeObjectURL;
    URL.revokeObjectURL = function (blobUrl) {
      try {
        blobUrlToMediaSource.delete(blobUrl);
        blobUrlToDirectSource.delete(blobUrl);
      } catch {}
      return origRevokeObjectURL.apply(this, arguments);
    };
  }
})();
