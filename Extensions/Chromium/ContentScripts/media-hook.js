// media-hook.js — Runs in the page's MAIN world at document_start.
// Intercepts manifest network fetches (fetch/XHR), MediaSource creation (URL.createObjectURL),
// and HTMLMediaElement src assignments to deterministically associate each <video> element
// with its specific HLS/DASH stream group (data-mdl-group attribute).
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
  // Players that transmux before appending (HLS .ts segments) append a new
  // buffer, so the identity is lost for them and those videos stay untagged.
  // That is deliberate: no timing, length or position is ever used to guess.
  const bufferSource = new WeakMap();        // ArrayBuffer -> URL it was fetched from
  const sourceBufferOwner = new WeakMap();   // SourceBuffer -> MediaSource
  const mediaSourceVideo = new WeakMap();    // MediaSource -> <video>
  const blobUrlToMediaSource = new Map();    // blob: URL -> MediaSource, until assigned or revoked
  // A blob URL is normally assigned to a <video> or revoked straight after it
  // is made. This only bounds the entries for a player that does neither, so
  // they cannot pile up (each one keeps a whole MediaSource alive).
  const MAX_PENDING_BLOB_URLS = 50;

  // Called as a blob: URL is assigned to a media element.
  function noteMediaSource(video, value) {
    if (typeof value !== 'string' || !value.startsWith('blob:')) return;
    const mediaSource = blobUrlToMediaSource.get(value);
    if (!mediaSource) return;
    blobUrlToMediaSource.delete(value);
    mediaSourceVideo.set(mediaSource, video);
  }

  function clearAssociation(video) {
    video.removeAttribute('data-mdl-group');
    video.removeAttribute('data-mdl-manifest');
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

  function attributeAppendedData(sourceBuffer, data) {
    const mediaSource = sourceBufferOwner.get(sourceBuffer);
    const video = mediaSource && mediaSourceVideo.get(mediaSource);
    if (!video) return;
    const buffer = ArrayBuffer.isView(data) ? data.buffer : data;
    const url = buffer && bufferSource.get(buffer);
    if (!url) return;
    const manifest = manifestForSegment(url);
    if (manifest) tagVideo(video, manifest.groupKey, manifest.url);
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
            noteMediaSource(this, val);
            resetAssociation(this, val);
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
          noteMediaSource(this, value);
          resetAssociation(this, value);
          handleMediaSrc(this, value);
        }
      } catch {}
      return origSetAttribute.apply(this, arguments);
    };
  }

  // ── 4. Intercept window.fetch ───────────────────────────────────────────────
  if (typeof window.fetch === 'function') {
    const origFetch = window.fetch;
    window.fetch = function (input, init) {
      try {
        let url = null;
        if (typeof input === 'string') url = input;
        else if (input instanceof URL) url = input.href;
        else if (input && typeof input.url === 'string') url = input.url;
        if (url && isManifestUrl(url)) {
          recordManifest(url);
        }
      } catch {}
      return origFetch.apply(this, arguments);
    };
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
        try { bufferSource.set(buffer, url); } catch {}
        return buffer;
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
                bufferSource.set(this.response, this.__mdlUrl || this.responseURL);
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
      try { blobUrlToMediaSource.delete(blobUrl); } catch {}
      return origRevokeObjectURL.apply(this, arguments);
    };
  }
})();
