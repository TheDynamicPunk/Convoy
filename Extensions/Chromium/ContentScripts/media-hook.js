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
      return origCreateObjectURL.apply(this, arguments);
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
})();
