// video-latch.js — IDM-style "latch" button that appears on hover over a
// <video> element, and becomes persistent as soon as the background resolves
// an HLS/DASH manifest for the active player.
(function () {
  const LATCHED_ATTR = 'data-mdl-latched';
  // Marks a pill as "visible without hovering". YouTube watch pages use it
  // immediately; generic pages use it once a resolved HLS/DASH manifest is
  // pushed in from the background worker.
  const PERSISTENT_ATTR = 'data-mdl-persistent';
  const latches = new Map(); // video element -> { button, panel }

  // ── Extension context invalidation ──────────────────────────────────────
  // When the extension is reloaded or updated — which for an end user means
  // any app update that reinstalls it — scripts already running in open pages
  // are orphaned: chrome.runtime.id goes undefined and every API on it throws.
  // The orphaned instance can never reconnect. That is a platform limit, not
  // something to work around here.
  //
  // What it *can* still do is reload the page: location.reload() is plain page
  // JS and needs no extension context. So rather than leaving a pill that
  // looks alive and silently does nothing when clicked, each pill relabels
  // itself into a one-click reload control.
  const STALE_ATTR = 'data-mdl-stale';

  // The popup's master switch. latch-off.css hides every [data-mdl-latch]
  // while <html> carries data-mdl-off — a manifest stylesheet, so a page's
  // CSP can't block it, and flipping the switch applies to open tabs live.
  function applyCaptureEnabled(enabled) {
    document.documentElement.toggleAttribute('data-mdl-off', enabled === false);
  }
  try {
    chrome.storage.local.get('captureEnabled', (r) => applyCaptureEnabled(r?.captureEnabled));
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === 'local' && changes.captureEnabled) applyCaptureEnabled(changes.captureEnabled.newValue);
    });
  } catch (_) {}
  const flashTimers = new WeakMap();

  function isExtensionAlive() {
    try {
      return Boolean(chrome.runtime?.id);
    } catch (_) {
      return false;
    }
  }

  // Relabels in place rather than removing the pill. A pill that simply
  // disappears is indistinguishable from "no video detected" or "the app
  // isn't running", so it tells the user nothing about how to get back to a
  // working state.
  function markLatchStale(latchState) {
    const btn = latchState?.btn;
    if (!btn || btn.getAttribute(STALE_ATTR) === '1') return;
    // Only pills the user can already see get pinned open. Force-revealing a
    // hover pill that was never shown would put a message on every page with
    // a <video> on it — worse than the problem being reported. Hidden pills
    // still get the label, so it reads correctly if hover reveals them later.
    const wasVisible = btn.getAttribute(PERSISTENT_ATTR) === '1' || btn.style.opacity === '1';
    btn.setAttribute(STALE_ATTR, '1');
    if (latchState.panel) latchState.panel.style.display = 'none';
    const label = btn.querySelector('span');
    if (label) label.textContent = 'Convoy updated \u2014 click to reload';
    if (!wasVisible) return;
    // PERSISTENT_ATTR is what every hide path already checks; a stale pill
    // that vanishes on mouseout is easy to miss.
    btn.setAttribute(PERSISTENT_ATTR, '1');
    btn.style.opacity = '1';
    btn.style.pointerEvents = 'auto';
  }

  function markAllLatchesStale() {
    for (const [, latchState] of latches) markLatchStale(latchState);
  }

  // chrome.runtime.sendMessage throws synchronously once the context is
  // invalidated, so every call site in this file routes through here: a dead
  // context becomes a relabelled pill instead of an uncaught TypeError in the
  // page console. Returns false if the message never went out.
  function safeSendMessage(message, callback) {
    try {
      chrome.runtime.sendMessage(message, callback);
      return true;
    } catch (_) {
      // The context is per-page, so one throw means every pill here is dead.
      markAllLatchesStale();
      return false;
    }
  }

  // Per-domain routing decision: which sites hand off entirely to the app's
  // yt-dlp pipeline (no local DOM/network sniffing at all) vs. which fall
  // back to generic <video>/<source> DOM sniffing (collectSources below).
  // YouTube is yt-dlp-only, deliberately, with no browser-capture fallback:
  // SABR makes capture unreliable, and yt-dlp already does the whole job end
  // to end.
  //
  // Future entries (Instagram, Pinterest, etc.) get added here as their own
  // strategy once built, rather than growing another ad hoc hostname check
  // in the click handler below.
  const SITE_STRATEGIES = [
    {
      name: 'youtube',
      // isYouTubeHost is declared below — fine, since this only ever runs from
      // currentStrategy() long after the IIFE body has finished evaluating.
      test: () => isYouTubeHost(),
      strategy: 'ytdlp',
    },
    {
      name: 'pinterest',
      test: () => /(?:^|\.)pinterest\.(?:com|fr|de|ch|jp|cl|ca|it|co\.uk|nz|ru|com\.au|at|pt|co\.kr|es|com\.mx|dk|ph|th|com\.uy|co|nl|info|kr|ie|vn|com\.vn|ec|mx|in|pe|co\.at|hu|co\.in|co\.nz|id|com\.ec|com\.py|tw|be|uk|com\.bo|com\.pe)$/i.test(location.hostname),
      strategy: 'sniff',
      titleExtractor: pinterestTitleExtractor,
    },
  ];

  function currentStrategy() {
    const match = SITE_STRATEGIES.find((s) => s.test());
    return match ? match.strategy : 'sniff';
  }

  function isYouTubeHost() {
    return /(^|\.)youtube\.com$/.test(location.hostname) || location.hostname === 'youtu.be';
  }

  // Only watch/shorts pages get the always-visible latch. The YouTube home
  // page, search results and channel pages all play muted inline <video>
  // previews on thumbnail hover, so an unconditional pill would sprout on
  // every tile in the grid.
  function isYouTubeWatchPage() {
    if (!isYouTubeHost()) return false;
    if (location.hostname === 'youtu.be') return location.pathname.length > 1;
    return location.pathname === '/watch' || location.pathname.startsWith('/shorts/');
  }

  // The player element wrapping the real video, as opposed to a thumbnail
  // preview elsewhere on the page.
  function mainPlayerContainer() {
    // Checked in priority order rather than as one comma-separated selector:
    // querySelector with a list returns the first match in *document* order,
    // not the first selector's match, and a watch page can contain more than
    // one .html5-video-player (sidebar previews). The ids are unambiguous.
    return document.querySelector('#movie_player')
      || document.querySelector('#shorts-player')
      || document.querySelector('.html5-video-player');
  }

  function isMainPlayerVideo(video) {
    const player = mainPlayerContainer();
    return !!player && player.contains(video);
  }

  // True when this video should carry a pill that's visible without hovering.
  function wantsPersistentLatch(video) {
    return isYouTubeWatchPage() && isMainPlayerVideo(video);
  }

  // Recursively searches open shadow roots for elements matching `selector`.
  // Used as a secondary sweep in scan() to find <video> elements inside Web
  // Components (Reddit's <shreddit-player>, modern player libraries, etc.)
  // that document.querySelectorAll cannot reach.
  function querySelectorAllDeep(selector, root = document) {
    let results = Array.from(root.querySelectorAll(selector));
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) {
        results = results.concat(querySelectorAllDeep(selector, el.shadowRoot));
      }
    }
    return results;  
  }

  // Known-generic aria-label/alt strings Pinterest uses for UI chrome or auto-generated placeholders.
  // Applied to every candidate so placeholder strings cannot leak through as filenames.
  const PINTEREST_GENERIC_LABELS = /^(pin\b|image\b|items?\s+to\s+explore|shop\s+(this|the\s+look|similar|now)|similar\s+items?|save\s+(pin|to\s+board)|more\s+like\s+this|visual\s+search|close\s+(pin|modal|dialog)|pinterest|home\s+feed|board\s+containing)/i;

  function isPinterestGenericLabel(text) {
    if (!text || typeof text !== 'string') return true;
    const trimmed = text.trim();
    if (trimmed.length <= 3) return true;
    if (PINTEREST_GENERIC_LABELS.test(trimmed)) return true;
    // Auto-generated board labels like "Pin on Girls", "Pin on Outfits", etc.
    if (/^pin\s+on\b/i.test(trimmed)) return true;
    return false;
  }

  // Decodes HTML entities (&amp;, &#39;, &quot;, etc.) that can leak
  // through from sources the browser doesn't auto-decode. The main
  // offender: <script> is an HTML "raw text" element, so &amp; inside a
  // JSON-LD <script type="application/ld+json"> block is never decoded by
  // the parser — a CMS that mistakenly HTML-escapes its JSON-LD payload
  // (JSON doesn't need HTML escaping; this is a real, common bug) leaves a
  // literal "&amp;" sitting in whatever JSON.parse hands back, which then
  // flows straight through to the filename. Same class of bug can double-
  // escape a meta[content] attribute too. Decoding via a detached textarea
  // (never appended to the document, so nothing in it executes) covers
  // every named/numeric entity correctly rather than hand-rolling a table
  // of the common ones.
  function decodeHtmlEntities(str) {
    if (!str || typeof str !== 'string' || !str.includes('&')) return str;
    const el = document.createElement('textarea');
    el.innerHTML = str;
    return el.value;
  }

  // -- Opaque identifier rejection ----------------------------------------
  // A CDN object key, content hash, UUID or timestamp is a perfectly legal
  // filename, so nothing downstream catches it -- sanitisation only removes
  // illegal characters. But a download named after a CDN object key is
  // useless to the person who made it, and on gallery-style sites that key is
  // exactly what the URL's last path component holds.
  //
  // Deliberately biased toward KEEPING a name. A wrongly rejected title costs
  // a fall back to the page title, which is usually still reasonable; but
  // rejecting too eagerly would strip the real per-item name off every
  // download on a site. So every rule below requires positive evidence of
  // machine origin, never merely the absence of evidence of human origin.
  const OPAQUE_MIN_LENGTH = 8;   // below this, "S01E04" and "4K60fps" are meaningful and too short to judge
  const OPAQUE_MIN_WORD_RUN = 5; // shorter runs turn up inside random keys by chance

  // Parts that describe the delivery pipeline rather than the video.
  const STRUCTURAL_TOKENS = new Set([
    'video', 'media', 'stream', 'playlist', 'manifest', 'master', 'index',
    'chunk', 'segment', 'output', 'file', 'download', 'content', 'asset',
    'source', 'default', 'untitled', 'temp', 'tmp', 'hls', 'dash', 'mp4',
    'clip', 'movie', 'track', 'part', 'render', 'export', 'main', 'full',
  ]);

  function isStructuralToken(token) {
    if (!token) return true;
    if (/^\d+$/.test(token)) return true;
    if (STRUCTURAL_TOKENS.has(token)) return true;
    // Resolution and codec fragments: "1080p", "720p60", "v2", "x264", "4k".
    const letters = token.replace(/[^a-z]/g, '');
    return letters.length <= 2 && /\d/.test(token);
  }

  // Longest run of letters that contains at least one vowel. A run this long
  // is taken as a real word, which is what keeps "20240615_familybbq" and
  // "my-vacation-video" intact, while a key whose longest letter run is only
  // three or four characters gets no credit for it.
  function longestWordRun(value) {
    let best = 0;
    for (const run of value.match(/[a-z]+/g) || []) {
      if (run.length > best && /[aeiouy]/.test(run)) best = run.length;
    }
    return best;
  }

  // Number of places where the string crosses between a letter and a digit.
  function alphanumericAlternations(value) {
    let count = 0;
    for (let i = 1; i < value.length; i++) {
      const previous = value[i - 1];
      const current = value[i];
      const previousLetter = previous >= 'a' && previous <= 'z';
      const currentLetter = current >= 'a' && current <= 'z';
      const previousDigit = previous >= '0' && previous <= '9';
      const currentDigit = current >= '0' && current <= '9';
      if ((previousLetter && currentDigit) || (previousDigit && currentLetter)) count++;
    }
    return count;
  }

  function looksOpaqueIdentifier(raw) {
    if (!raw || typeof raw !== 'string') return true;
    // Judge the stem: a trailing ".mp4" would otherwise donate the letters and
    // vowels that make an opaque key read as a word.
    const trimmed = raw.trim();
    const s = trimmed.replace(/\.[a-z0-9]{1,5}$/i, '') || trimmed;
    if (!s) return true;
    if (s.length < OPAQUE_MIN_LENGTH) return false;
    // Whitespace is the strongest human signal there is.
    if (/\s/.test(s)) return false;
    // Scripts that do not space their words -- CJK, Thai, Khmer, Hangul --
    // would be judged by rules written for Latin text and rejected wholesale.
    if (/[^\u0000-\u02ff]/.test(s)) return false;

    const lower = s.toLowerCase();
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(lower)) return true;

    const digits = (lower.match(/\d/g) || []).length;
    const letters = (lower.match(/[a-z]/g) || []).length;
    // A pure number is a timestamp, a counter or an id.
    if (letters === 0 && digits >= OPAQUE_MIN_LENGTH) return true;
    // A long pure-hex run is a hash or an object key. The digit requirement
    // matters: "a" through "f" are also letters, so without it any long word
    // spelled from that alphabet ("aaaaaaaaaaaa", "deadbeefcafe") reads as a
    // hash. A real hex hash of this length without a single digit has odds
    // around one in a hundred trillion.
    if (/^[0-9a-f]+$/.test(lower) && /\d/.test(lower) && lower.length >= 12) return true;

    // Every part describes the pipeline: "hls_playlist_1080p" names no video.
    const tokens = lower.split(/[-_. ]+/).filter(Boolean);
    if (tokens.length >= 2 && tokens.every(isStructuralToken)) return true;

    // Letters and digits crossing back and forth repeatedly is a machine key.
    // People put digits at the edges of a name -- a year, a date, a resolution
    // -- not woven through it: "berlin2024" and "HDR10PlusTest" cross once or
    // twice, while a key such as "k3variol8mqz71bn" crosses six times.
    //
    // This has to run BEFORE the word-run rule below. A long random key will
    // contain a vowel-bearing letter run purely by chance -- "variol" in the
    // key above -- and the word rule would otherwise read it as English and
    // keep the whole string. A real CDN key survived this check that way.
    if (s.length >= 12 && alphanumericAlternations(lower) >= 4) return true;

    // Contains a real word -- keep it, whatever the digits around it look like.
    if (longestWordRun(lower) >= OPAQUE_MIN_WORD_RUN) return false;

    // Past here there is no word anywhere in the string.
    const ratio = digits / s.length;
    if (ratio >= 0.3 && s.length >= 10) return true;
    if (s.length >= 10 && !/[aeiou]/.test(lower)) return true;
    if (s.length >= 16 && ratio > 0.15) return true;
    return false;
  }

  // A title is usable when it exists and is not a machine identifier. A tier
  // that produces one now falls through to the next instead of being
  // accepted, so an id-shaped aria-label can no longer beat a real page title.
  function isUsableTitle(title) {
    return Boolean(title) && !looksOpaqueIdentifier(title);
  }

  function cleanTitleForFilename(title) {
    if (!title || typeof title !== 'string') return null;
    let t = decodeHtmlEntities(title).trim();
    // Normalize Unicode non-breaking and special spaces to standard ASCII space
    t = t.replace(/[\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]/g, ' ');
    // Strip leading aesthetic symbols/arrows (e.g. "╰┈➤", "•", "—", "-")
    t = t.replace(/^[╰┈➤\s•|—\-~:]+/, '').trim();
    return t || null;
  }

  function cleanPinterestTitle(text) {
    if (!text || typeof text !== 'string') return null;
    let t = cleanTitleForFilename(text);
    if (!t) return null;
    if (isPinterestGenericLabel(t)) return null;
    return t || null;
  }

  // Pinterest: extract the pin's title from the video's nearest pin container or page context.
  //
  // Pinterest has THREE distinct contexts where a video can appear:
  //
  //   A. FEED CARD (masonry grid, related pins "More like this", board view)
  //      Container: [data-test-id="pinWrapper"], [data-grid-item], or feed pin card.
  //      Title source: img[alt], a[aria-label], or card title elements.
  //
  //   B. CLOSEUP MODAL (SPA navigation via history.pushState to /pin/<id>/)
  //      Container: [role="dialog"].
  //      Title source: h1/h2 inside the modal, or [data-test-id*="title"] elements.
  //
  //   C. STANDALONE PIN PAGE (direct navigation to /pin/<id>/)
  //      The main video is in the media column, while the title is in the adjacent details column.
  //      Title source: [data-test-id="pin-title"] h1, [data-test-id="CloseupDetails"] h1, or h1.
  function pinterestTitleExtractor(video) {
    if (!video) return null;

    // ── 1. Closeup Modal (SPA overlay dialog) ─────────────────────────────────
    const modal = video.closest('[role="dialog"]');
    if (modal) {
      const h1 = modal.querySelector('[data-test-id="pin-title"] h1, [data-test-id="pin-title"], [data-test-id="CloseupDetails"] h1, h1');
      if (h1) {
        const cleaned = cleanPinterestTitle(h1.textContent);
        if (cleaned) return cleaned;
      }
      const titleEl = modal.querySelector('[data-test-id*="title" i]');
      if (titleEl) {
        const cleaned = cleanPinterestTitle(titleEl.textContent);
        if (cleaned) return cleaned;
      }
      const descEl = modal.querySelector('[data-test-id="truncated-description"], [data-test-id*="description" i]');
      if (descEl) {
        const cleaned = cleanPinterestTitle(descEl.textContent);
        if (cleaned) return cleaned;
      }
      const img = modal.querySelector('img[alt]');
      if (img) {
        const cleaned = cleanPinterestTitle(img.alt);
        if (cleaned) return cleaned;
      }
      return null;
    }

    // ── 2. Standalone Pin Page (/pin/<id>/) ───────────────────────────────────
    // If we are on a /pin/<id>/ page and this video is NOT inside the related pins grid,
    // it is unequivocally the MAIN PIN of the page.
    const isFeedCard = !!video.closest(
      '[data-test-id="feed"], [data-test-id="grid"], [data-test-id="masonry-container"], [data-grid-item="true"], [data-test-id="pinWrapper"]'
    );
    if (!isFeedCard && location.pathname.includes('/pin/')) {
      // 1. Main title element in the DOM (e.g. <div data-test-id="pin-title"><h1>the pin's title</h1></div>)
      const h1 = document.querySelector('[data-test-id="pin-title"] h1, [data-test-id="pin-title"], [data-test-id="CloseupDetails"] h1, h1');
      if (h1) {
        const cleaned = cleanPinterestTitle(h1.textContent);
        if (cleaned) return cleaned;
      }

      // 2. Pin description element or meta tags
      const descEl = document.querySelector('[data-test-id="truncated-description"], [data-test-id*="description" i]');
      if (descEl) {
        const cleaned = cleanPinterestTitle(descEl.textContent);
        if (cleaned) return cleaned;
      }

      const ogDesc = document.querySelector('meta[property="og:description"]')?.content ||
                     document.querySelector('meta[name="description"]')?.content;
      if (ogDesc) {
        let descText = ogDesc.replace(/^[0-9A-Za-z-]+\s*—\s*/, '').trim();
        const firstPart = descText.split(/[|•—]/)[0]?.trim();
        const cleaned = cleanPinterestTitle(firstPart || descText);
        if (cleaned) return cleaned;
      }

      // 3. og:title / twitter:title (validated against isPinterestGenericLabel)
      const ogTitle = document.querySelector('meta[property="og:title"]')?.content ||
                      document.querySelector('meta[name="twitter:title"]')?.content;
      if (ogTitle) {
        const cleaned = cleanPinterestTitle(ogTitle);
        if (cleaned) return cleaned;
      }

      // 4. document.title (validated against isPinterestGenericLabel)
      const pageTitle = cleanPinterestTitle(document.title);
      if (pageTitle) return pageTitle;

      // 5. Fallback for standalone pin: ID from URL pathname (e.g. /pin/<id>/ -> "pin-<id>")
      const pinIdMatch = location.pathname.match(/\/pin\/(\d+)/);
      if (pinIdMatch) return `pin-${pinIdMatch[1]}`;
    }

    // ── 3. Feed Card (related pins grid or home feed) ─────────────────────────
    if (isFeedCard || !location.pathname.includes('/pin/')) {
      const feedPin = video.closest(
        '[data-grid-item="true"], [data-test-id="pinWrapper"], [data-test-id="PinCard"]'
      ) || video.closest('[data-test-id="masonry-container"] > div') || video.parentElement;
      if (feedPin) {
        const titleEl = feedPin.querySelector('[data-test-id*="title" i]');
        if (titleEl) {
          const cleaned = cleanPinterestTitle(titleEl.textContent);
          if (cleaned) return cleaned;
        }

        const img = feedPin.querySelector('img[alt]');
        if (img) {
          const cleaned = cleanPinterestTitle(img.alt);
          if (cleaned) return cleaned;
        }

        const link = feedPin.querySelector('a[aria-label]');
        if (link) {
          const cleaned = cleanPinterestTitle(link.getAttribute('aria-label'));
          if (cleaned) return cleaned;
        }

        const vLabel = video.getAttribute('aria-label') || video.getAttribute('title');
        if (vLabel) {
          const cleaned = cleanPinterestTitle(vLabel);
          if (cleaned) return cleaned;
        }
      }
      return null; // exhausted feed card signals
    }

    return null;
  }

  // Generic heuristic: walk up from the <video>, crossing shadow boundaries,
  // and inspect EVERY ancestor node for direct title metadata — not just standard
  // HTML semantic containers (article, section, figure).
  //
  // The key insight: modern SPAs (Reddit, Mux, Vidstack) use W3C Custom Elements
  // (<shreddit-post>, <media-player>, …) that don't match the legacy HTML4 tag
  // whitelist. Those custom elements store titles as host attributes (e.g.
  // post-title="…") or as slotted children (<a slot="title">…</a>). By checking
  // attributes on EVERY step we catch these naturally — no per-site code needed.
  //
  // Walk priority per node (first non-empty wins, then continue climbing):
  //   A. Direct title attributes:  post-title, data-title, data-video-title
  //   B. [slot="title"] light-DOM child (Web Component projection convention)
  //   C. Once a semantic container is found: headings, .title class elements, aria-label
  //   D. Fallback if C finds nothing usable, in order:
  //      D1. The closest ancestor's h1[class*="title"] — metascraper-title's
  //          own signal for this exact situation (a title-classed heading
  //          with no semantic wrapper around it).
  //      D2. The closest ancestor whose subtree contains exactly one bare
  //          <h1> — looser than D1, only tried if D1 finds nothing.
  //
  // NOT used on Pinterest — see pinterestTitleExtractor comment above.
  // -- Per-item name resolution -------------------------------------------
  // Sites vary too much for an ordered "first match wins" chain: whichever
  // signal happens to be checked first wins even when a far better one sits
  // one element away. So every signal within reach is collected as a scored
  // candidate and the best is chosen at the end.
  //
  // Two things set a candidate's score:
  //
  //   Kind  - how deliberately the site marked it up. A <figcaption> or an
  //           [itemprop="name"] is an author stating "this names the media";
  //           a link's href slug is a guess that usually happens to work.
  //   Depth - how far up the ancestor chain it was found, one point per
  //           level, so a weaker signal sitting right beside the video beats
  //           a stronger one that belongs to the page rather than the item.
  //
  // The depth term is what gallery layouts need. A masonry grid item has no
  // <article>/<section> wrapper, so the previous container-gated search never
  // ran for it, and the two container-free fallbacks it fell back on looked
  // only at <h1> - which a grid item never has, because the page owns the
  // single <h1> and items use <h2>/<h3>.
  const NAME_CONFIDENCE = {
    directAttribute: 90,  // post-title / data-title / data-video-title
    slottedTitle: 84,     // <custom-el><a slot="title">
    itempropName: 78,     // schema.org microdata
    figcaption: 72,       // <figure> wrapping this video
    heading: 66,          // unlinked h1/h2/h3 that unambiguously belongs to this item
                          // - ranked ABOVE cardLinkTitle on purpose: where a
                          // page shows the item's own title as a heading, any
                          // permalink in reach belongs to a DIFFERENT post
                          // (a "More Posts" sidebar), so the heading wins
    titleClass: 54,       // [class*="title"], [class*="caption"]
    linkLabel: 48,        // aria-label / title on the enclosing anchor
    mediaLabel: 42,       // aria-label / title / aria-labelledby on <video>
    previewAlt: 58,       // alt of the image poster= names as this video's preview
    posterAlt: 36,        // alt text of the item's thumbnail
    linkSlug: 33,         // last usable path segment of an ANCESTOR anchor's href
    cardLinkTitle: 64,    // text of a card permalink, confirmed against its own slug
    cardLinkSlug: 28,     // permalink found elsewhere in the card, not above the video
    linkText: 30,         // visible text of the enclosing anchor
    containerLabel: 24,   // aria-label on a semantic container
  };
  const MAX_NAME_CLIMB = 15;

  // Path segments that are routing, never the name of the thing being routed
  // to. Kept separate from STRUCTURAL_TOKENS so that widening it for URLs
  // cannot change how the shape test judges ordinary titles.
  const PATH_NOISE_SEGMENTS = new Set([
    'watch', 'embed', 'player', 'view', 'item', 'items', 'post', 'posts',
    'page', 'detail', 'details', 'gallery', 'album', 'videos', 'video',
    'media', 'content', 'stream', 'streams', 'clip', 'clips', 'en', 'www',
  ]);

  // Boilerplate that sites put in alt text, aria-labels and headings. Not a
  // title, and worse than no name at all: "Video thumbnail" looks enough like
  // a real name to survive a glance, so nothing downstream questions it.
  const GENERIC_MEDIA_WORDS = new Set([
    'video', 'videos', 'thumbnail', 'thumb', 'preview', 'image', 'img',
    'photo', 'picture', 'play', 'player', 'poster', 'cover', 'media',
    'banner', 'placeholder', 'untitled', 'logo', 'icon', 'avatar', 'button',
    'loading', 'default', 'clip', 'movie', 'watch', 'stream', 'embed',
  ]);
  // Dropped before judging, so "Play the video" reads as generic the same way
  // "Play video" does.
  const LABEL_STOPWORDS = new Set([
    'the', 'a', 'an', 'this', 'that', 'to', 'of', 'on', 'in', 'and', 'for',
    'is', 'it', 'or', 'with',
  ]);

  function isGenericMediaLabel(text) {
    if (!text) return true;
    const words = (text.toLowerCase().match(/[a-z]+/g) || [])
      .filter((word) => !LABEL_STOPWORDS.has(word));
    if (!words.length) return true;
    return words.every((word) => GENERIC_MEDIA_WORDS.has(word));
  }

  // Page and card furniture rather than the video's preview. Class and alt are
  // both checked because sites label these in one place or the other, and
  // rarely in both.
  const NON_PREVIEW_IMAGE = /avatar|logo|icon|badge|profile|channel|author|user|sponsor|advert|promo|emoji|spinner|placeholder/i;

  function isNonPreviewImage(img) {
    const marks = `${img.getAttribute('class') || ''} ${img.getAttribute('alt') || ''}`;
    if (NON_PREVIEW_IMAGE.test(marks)) return true;
    return isGenericMediaLabel(img.getAttribute('alt'));
  }

  function labelledByText(el) {
    const ids = el?.getAttribute?.('aria-labelledby');
    if (!ids) return null;
    const text = ids.trim().split(/\s+/)
      .map((id) => document.getElementById(id)?.textContent?.trim())
      .filter(Boolean)
      .join(' ');
    return text || null;
  }

  function absoluteUrl(raw) {
    if (!raw || typeof raw !== 'string') return null;
    try { return new URL(raw, location.href).href; } catch { return null; }
  }

  // A gallery card's href is frequently the best name anywhere on the page:
  // /videos/sunset-over-the-bay reads perfectly. /videos/k3variol8mqz71bn
  // does not. The shape test is the only thing that
  // tells those apart, and it has to run on the RAW segment - prettifying
  // first would insert spaces and make every slug look human-written.
  //
  // Segments are examined right to left so a trailing id does not hide a
  // readable slug earlier in the path, and vice versa.
  // Lowercase, drop punctuation, join on underscores. Mirrors how sites build
  // a permalink slug out of a title, so a slug can be compared back against
  // candidate text: "Don't look...now!" and "dont_look_now" agree.
  function slugifyForComparison(text) {
    return String(text)
      .toLowerCase()
      .replace(/[^a-z0-9\s]+/g, '')
      .trim()
      .replace(/\s+/g, '_');
  }

  function slugTitleFromHref(href) {
    const absolute = absoluteUrl(href);
    if (!absolute) return null;
    let segments;
    try { segments = new URL(absolute).pathname.split('/').filter(Boolean); } catch { return null; }
    for (let i = segments.length - 1; i >= 0; i--) {
      let segment;
      try { segment = decodeURIComponent(segments[i]); } catch { segment = segments[i]; }
      segment = segment.replace(/\.[a-z0-9]{1,5}$/i, '');
      if (segment.length <= 2) continue;
      if (PATH_NOISE_SEGMENTS.has(segment.toLowerCase())) continue;
      if (looksOpaqueIdentifier(segment)) continue;
      const pretty = segment.replace(/[-_+]+/g, ' ').replace(/\s+/g, ' ').trim();
      if (pretty.length > 2) return pretty;
    }
    return null;
  }

  function genericTitleForVideo(video) {
    if (!video) return null;

    const candidates = [];
    const add = (raw, confidence, source) => {
      if (!raw || typeof raw !== 'string') return;
      // textContent arrives with the source file's newlines and indentation in
      // it, so collapse before anything judges the length or the shape.
      const collapsed = raw.replace(/\s+/g, ' ').trim();
      const cleaned = cleanTitleForFilename(collapsed);
      if (!cleaned || cleaned.length <= 2 || cleaned.length > 300) return;
      if (looksOpaqueIdentifier(cleaned)) return;
      if (isGenericMediaLabel(cleaned)) return;
      candidates.push({ text: cleaned, confidence, source });
    };

    // Only an unambiguous match counts. Two headings inside one ancestor means
    // neither is known to describe this video, and taking either is exactly
    // how a page masthead ends up as a filename.
    const addUnique = (node, selector, confidence, source) => {
      const found = node.querySelectorAll?.(selector);
      if (found?.length === 1) add(found[0].textContent, confidence, source);
    };

    // -- The video element's own accessible name ---------------------------
    add(video.getAttribute('aria-label'), NAME_CONFIDENCE.mediaLabel, 'video[aria-label]');
    // The plain `title` attribute is trusted only on the media element and on
    // the enclosing anchor. On arbitrary ancestors it is tooltip text - links,
    // icons and buttons all carry it - which is far too noisy to rank.
    add(video.getAttribute('title'), NAME_CONFIDENCE.mediaLabel, 'video[title]');
    add(labelledByText(video), NAME_CONFIDENCE.mediaLabel, 'video[aria-labelledby]');
    add(video.getAttribute('data-title'), NAME_CONFIDENCE.directAttribute, 'video[data-title]');

    // -- The image poster= names as this video's preview --------------------
    // The attribute says which image belongs to this video, so its alt is
    // describing this video and nothing else on the page. Far more precise
    // than guessing which of a card's images is the preview, and it is the
    // only image signal that stays reliable when a card holds several.
    const poster = absoluteUrl(video.getAttribute('poster'));
    if (poster) {
      for (const img of document.querySelectorAll('img[alt]')) {
        if (absoluteUrl(img.getAttribute('src')) === poster) {
          add(img.getAttribute('alt'), NAME_CONFIDENCE.previewAlt, 'poster img[alt]');
          break;
        }
      }
    }

    // -- The enclosing anchor: a gallery card is nearly always a link -------
    const anchor = video.closest?.('a[href]');
    if (anchor) {
      add(anchor.getAttribute('aria-label'), NAME_CONFIDENCE.linkLabel, 'a[aria-label]');
      add(anchor.getAttribute('title'), NAME_CONFIDENCE.linkLabel, 'a[title]');
      add(labelledByText(anchor), NAME_CONFIDENCE.linkLabel, 'a[aria-labelledby]');
      // The slug outranks the anchor's text on purpose. A card link wraps the
      // whole card, so its textContent picks up whatever chrome is painted
      // over the thumbnail, which on a hover-preview player is typically its
      // time readout, literally "0.00/0.00". A slug that has already survived the shape test
      // is a deliberate, item-specific string; loose text inside the card is
      // not, and it should never be able to displace one.
      add(slugTitleFromHref(anchor.getAttribute('href')), NAME_CONFIDENCE.linkSlug, 'a href slug');
      add(anchor.textContent, NAME_CONFIDENCE.linkText, 'a text');
    }

    // -- An explicit caption for this media --------------------------------
    const figure = video.closest?.('figure');
    if (figure) addUnique(figure, 'figcaption', NAME_CONFIDENCE.figcaption, 'figcaption');

    // -- Ancestor walk ------------------------------------------------------
    let node = video;
    let depth = 0;
    while (node && node !== document.body && node !== document.documentElement && depth <= MAX_NAME_CLIMB) {
      const penalty = depth;

      const direct = node.getAttribute?.('post-title')
                  || node.getAttribute?.('data-title')
                  || node.getAttribute?.('data-video-title');
      add(direct, NAME_CONFIDENCE.directAttribute - penalty, 'direct attribute');

      // Web Component slot projection: a custom element may receive its title
      // as a light-DOM child carrying slot="title". Gated on the hyphen that
      // marks a custom element, so this is not a querySelector on every
      // ancestor.
      if (node.localName?.includes('-')) {
        addUnique(node, '[slot="title"]', NAME_CONFIDENCE.slottedTitle - penalty, 'slot=title');
      }

      addUnique(node, '[itemprop="name"], [itemprop="headline"]', NAME_CONFIDENCE.itempropName - penalty, 'itemprop');

      // Headings, minus the ones that are navigation.
      //
      // A media page puts the item's title in a plain heading and makes every
      // OTHER heading a link: the author, the section it belongs to, a "more
      // from this author" label, and each entry listed under it. Filtering
      // those out is what keeps the real title unambiguous in a layout where
      // the media and the caption live in separate columns and their nearest
      // shared ancestor also contains a sidebar of other items - an
      // expanded-player layout is exactly that, with a dozen headings under
      // the common ancestor and only one of them belonging to the video on
      // screen.
      //
      // A heading wrapped in a DEEP link is still a title (some sites make the
      // whole card, heading included, one permalink); only a shallow wrapper
      // means the heading names a feed rather than an item.
      const headings = Array.from(node.querySelectorAll?.('h1, h2, h3') || [])
        .filter((heading) => {
          if (heading.querySelector('a[href]')) return false;
          const wrapper = heading.closest('a[href]');
          if (!wrapper) return true;
          try {
            return new URL(wrapper.getAttribute('href'), location.href)
              .pathname.split('/').filter(Boolean).length >= 3;
          } catch { return false; }
        });
      if (headings.length === 1) {
        add(headings[0].textContent, NAME_CONFIDENCE.heading - penalty, 'heading');
      }
      addUnique(node, '[class*="title" i], [class*="caption" i]', NAME_CONFIDENCE.titleClass - penalty, 'title class');

      // A permalink somewhere else in the card.
      //
      // closest('a[href]') only walks ancestors, so it finds nothing when the
      // media and the caption are laid out as sibling branches - which is what
      // a virtualised grid does: the <video> has no anchor above it at all,
      // while the item link sits in a neighbouring subtree. Every other signal in such a card is absent or
      // ambiguous too, so without this the name falls through to the page
      // title and every card on the page downloads under one name.
      //
      // Links are ranked by path DEPTH. An item permalink is deep
      // (/section/sub/items/id/slug); the navigation around it - the section,
      // the author, a tag search - is shallow. Depth separates them without
      // knowing anything about the site, where "does the slug read as several
      // words" does not: an author link like /author/Some-Hyphenated-Name
      // yields a perfectly multi-word slug and used to make this whole lookup
      // give up as ambiguous.
      //
      // Uniqueness is still required among the deepest, so a level wide enough
      // to hold two different posts is skipped rather than guessed at.
      const links = node.querySelectorAll?.('a[href]');
      if (links?.length) {
        const byHref = new Map();
        for (const link of links) {
          const href = link.getAttribute('href');
          if (!href) continue;
          if (!byHref.has(href)) {
            const slug = slugTitleFromHref(href);
            if (!slug) continue;
            let depth;
            try {
              depth = new URL(href, location.href).pathname.split('/').filter(Boolean).length;
            } catch { continue; }
            byHref.set(href, { slug, depth, links: [] });
          }
          byHref.get(href)?.links.push(link);
        }

        const entries = [...byHref.values()];
        if (entries.length) {
          const deepest = Math.max(...entries.map((e) => e.depth));
          const contenders = entries.filter((e) => e.depth === deepest);
          const slugs = new Set(contenders.map((e) => e.slug));
          if (slugs.size === 1) {
            const slug = contenders[0].slug;
            // The slug is a lossy copy of the title: the site lowercased it,
            // stripped its punctuation and cut it to a fixed length
            // ("don't...stop" arrives as "dontstop", and anything past roughly
            // fifty characters is simply gone). The untouched title is usually in
            // the link itself, so prefer that and keep the slug as fallback.
            //
            // Which link, though: the title and the "N comments" link share
            // one href. Slugifying the candidate text settles it - the
            // title's text slugifies back to the slug by construction, and
            // runs longer since the slug was truncated, while a sibling link
            // such as "3 comments" does not match at all.
            const wanted = slugifyForComparison(slug);
            let titleText = null;
            for (const entry of contenders) {
              for (const link of entry.links) {
                const text = (link.textContent || '').replace(/\s+/g, ' ').trim();
                if (!text || !slugifyForComparison(text).startsWith(wanted)) continue;
                if (!titleText || text.length > titleText.length) titleText = text;
              }
            }
            if (titleText) {
              add(titleText, NAME_CONFIDENCE.cardLinkTitle - penalty, 'card permalink text');
            }
            // Only trust a bare slug when something corroborates that this is
            // a post rather than a nav link: either its own link text matched,
            // or it reads as a real multi-word title.
            if (titleText || slug.split(' ').length >= 2) {
              add(slug, NAME_CONFIDENCE.cardLinkSlug - penalty, 'card permalink slug');
            }
          }
        }
      }

      // The item's thumbnail. Pinterest already mined this through its own
      // extractor; it is just as good a signal on every other site.
      //
      // Requiring the only image in scope was too strict to fire on real
      // markup: a card nearly always carries an uploader avatar, a badge or a
      // sponsor slot alongside the preview. Discard the images that are
      // plainly furniture first, then take the survivor only if it is
      // unambiguous - two real candidates still means neither is known to be
      // this video's.
      const previews = Array.from(node.querySelectorAll?.('img[alt]') || [])
        .filter((img) => !isNonPreviewImage(img));
      if (previews.length === 1) {
        add(previews[0].getAttribute('alt'), NAME_CONFIDENCE.posterAlt - penalty, 'img[alt]');
      }

      if (node.matches?.('article, section, figure, [role="article"], [role="main"]')) {
        add(node.getAttribute('aria-label'), NAME_CONFIDENCE.containerLabel - penalty, 'container aria-label');
      }

      depth++;
      // Cross a shadow boundary by jumping to the host, as the old walk did.
      node = node.parentElement || node.getRootNode?.()?.host || null;
    }

    if (!candidates.length) return null;
    // Stable sort, and candidates are added nearest-first, so an exact tie
    // resolves to the one closest to the video.
    candidates.sort((a, b) => b.confidence - a.confidence);
    return candidates[0].text;
  }


  // JSON-LD Schema.org VideoObject extraction. 45-60% of video sites include
  // this for Google/social indexing. Provides the most accurate video title
  // available — the name field is a Google-required property, so when present
  // it's virtually always correct and specific.
  //
  // Searches all <script type="application/ld+json"> blocks for objects where
  // @type is VideoObject, Clip, Movie, or TVEpisode. Handles @graph arrays
  // (WordPress, news sites) and nested structures.
  const VIDEO_LD_TYPES = new Set([
    'VideoObject', 'Clip', 'Movie', 'TVEpisode', 'TVSeries',
    'AudioObject', 'MediaObject',
  ]);

  // Every media object in the document's JSON-LD, each kept with the URLs that
  // say which <video> it describes.
  function collectJsonLdMediaObjects() {
    const found = [];
    const visit = (obj) => {
      if (!obj || typeof obj !== 'object') return;
      if (Array.isArray(obj)) { obj.forEach(visit); return; }
      if (VIDEO_LD_TYPES.has(obj['@type'])) {
        const raw = typeof obj.name === 'string' ? obj.name
                  : typeof obj.headline === 'string' ? obj.headline : null;
        if (raw && raw.trim().length > 2) {
          found.push({
            name: raw.trim(),
            urls: [obj.contentUrl, obj.embedUrl, obj.url, obj.thumbnailUrl]
              .flatMap((value) => (Array.isArray(value) ? value : [value]))
              .filter((value) => typeof value === 'string' && value),
          });
        }
      }
      // Recursing over every value covers @graph, itemListElement and the
      // arbitrary nesting that CMS plugins produce, with no per-shape cases.
      for (const value of Object.values(obj)) {
        if (value && typeof value === 'object') visit(value);
      }
    };
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      try { visit(JSON.parse(script.textContent)); } catch { /* malformed JSON, common */ }
    }
    return found;
  }

  // Scoped to the video that was actually clicked.
  //
  // This previously returned the FIRST VideoObject found in the document,
  // whichever video it described. Gallery sites emit one VideoObject per card
  // for SEO, so every download from such a page was named after item one - a
  // silently wrong name, which is worse than an obviously broken one because
  // nothing about it looks like a failure.
  function extractJsonLdVideoTitle(video) {
    const objects = collectJsonLdMediaObjects();
    if (!objects.length) return null;

    const identifiers = new Set();
    const remember = (raw) => {
      const absolute = absoluteUrl(raw);
      if (absolute) identifiers.add(absolute);
    };
    remember(video?.currentSrc);
    remember(video?.src);
    remember(video?.getAttribute?.('src'));
    remember(video?.getAttribute?.('poster'));
    for (const source of video?.querySelectorAll?.('source[src]') || []) {
      remember(source.getAttribute('src'));
    }

    for (const object of objects) {
      for (const url of object.urls) {
        const absolute = absoluteUrl(url);
        if (absolute && identifiers.has(absolute)) return object.name;
      }
    }

    // Nothing matched. One media object on a page holding one video is still
    // safe - that is the ordinary article or watch-page shape, where the
    // object plainly refers to the only video there is. More than one of
    // either and there is no way to know which it describes, so the DOM
    // signals are a better bet than a coin flip.
    if (objects.length === 1 && document.querySelectorAll('video').length <= 1) {
      return objects[0].name;
    }
    return null;
  }

  // Platform names that appear as bare document.title on feed / home pages
  // (e.g. <title>Reddit</title>, <title>YouTube</title>) — a bare brand name
  // is worse than no title at all.
  // Returning null lets the native app's streamFilename() fallback run, which
  // produces a better name from the manifest URL or referrer.
  const BARE_BRAND_TITLES = /^(reddit|youtube|vimeo|x|twitter|facebook|instagram|tiktok|dailymotion|twitch|pinterest|bilibili|tumblr|linkedin)$/i;

  function cleanedPageTitle() {
    const og = document.querySelector('meta[property="og:title"]')?.content?.trim();
    // Sites are inconsistent about which attribute they use for the Twitter
    // Card title tag — the spec says `name="twitter:title"`, but enough
    // sites emit `property="twitter:title"` instead (metascraper-title, a
    // widely-used metadata extraction library, checks both for exactly this
    // reason) that checking only one leaves real coverage on the table.
    const twitter = document.querySelector('meta[name="twitter:title"]')?.content?.trim()
                  || document.querySelector('meta[property="twitter:title"]')?.content?.trim();
    const raw = og || twitter || document.title?.trim();
    if (!raw) return null;
    const cleaned = cleanTitleForFilename(raw);
    const result = cleaned || raw;
    // Reject bare platform brand names — they are feed-page placeholders, not
    // video titles. A null here causes titleForVideo to return null, which
    // signals the native app to use its own manifest-based filename fallback.
    if (BARE_BRAND_TITLES.test(result)) return null;
    // A page whose og:title or <title> is itself an id — common on gallery
    // and CDN-backed sites — is no better a filename than the URL would be.
    if (looksOpaqueIdentifier(result)) return null;
    // On Pinterest, reject generic board placeholders like "Pin on Girls"
    if (location.hostname.includes('pinterest') && isPinterestGenericLabel(result)) return null;
    return result;
  }

  // Five-tier title resolution for the download filename:
  //   1. Site-specific extractor (e.g. Pinterest DOM traversal)
  //   2. JSON-LD Schema.org VideoObject.name (highest accuracy, 45-60% of sites)
  //   3. Generic heuristic (article/section heading) — skipped on Pinterest
  //   4. og:title / twitter:title
  //   5. document.title
  function titleForVideo(video) {
    const strategy = SITE_STRATEGIES.find((s) => s.test());

    // Tier 1: site-specific
    if (strategy?.titleExtractor) {
      const title = strategy.titleExtractor(video);
      if (isUsableTitle(title)) return title;
      // On Pinterest, if the video is a feed card (secondary video in a feed/grid)
      // and it had no title of its own, NEVER fall back to the main page's title!
      if (strategy.name === 'pinterest' && video.closest('[data-test-id="feed"], [data-test-id="grid"], [data-test-id="masonry-container"], [data-grid-item="true"], [data-test-id="pinWrapper"], [data-test-id="PinCard"]')) {
        return null;
      }
    }

    // Tier 2: JSON-LD structured data (most accurate when available)
    const jsonLdTitle = extractJsonLdVideoTitle(video);
    if (isUsableTitle(jsonLdTitle)) return jsonLdTitle;

    // Tier 3: generic heuristic — skip on Pinterest (false positives from feed section labels)
    if (!strategy || strategy.name !== 'pinterest') {
      const generic = genericTitleForVideo(video);
      if (isUsableTitle(generic)) return generic;
    }

    // Tier 4 & 5: page-level (og:title / document.title)
    return cleanedPageTitle();
  }

  // Sends the plain watch-page URL to the app and does nothing else — no
  // format list is fetched in the browser at all. The app opens (or comes
  // to front) with its own AddDownloadsView quality picker, which already
  // exists and already calls yt-dlp itself (NewDownloadView.swift). This is
  // the single hop the whole point of the yt-dlp-owns-YouTube decision was
  // to get to.
  function sendYouTubeToApp(pageUrl, btn) {
    safeSendMessage({ type: 'openYouTubeDownload', payload: { url: pageUrl } }, (response) => {
      // A native host that isn't running is the failure users actually hit
      // day to day, and it is not the same thing as a stale script. Say so on
      // the pill instead of only in the console, where a failed click is
      // indistinguishable from one that worked.
      // Reading lastError is also what suppresses Chrome's own "Unchecked
      // runtime.lastError" warning when the background never answers — the
      // exact kind of console noise this change exists to clear out. That
      // case arrives here as an undefined response, so it reports too.
      const failure = chrome.runtime.lastError;
      if (failure || !response || response.success === false) {
        console.error('[MDL] Failed to open Convoy for', pageUrl, ':',
          failure?.message || response?.error || 'no response');
        flashButtonMessage(btn, "Couldn't reach Convoy");
        return;
      }
      flashButtonMessage(btn, 'Sent to Convoy');
    });
  }

  // Reports the outcome of a click on the button itself — there's no panel to
  // show a result in for the ytdlp strategy, since nothing is fetched or
  // rendered in the page. Carries failures as well as confirmations: a click
  // that reached a dead native host used to log to the console and otherwise
  // look identical to one that worked.
  function flashButtonMessage(btn, text) {
    const label = btn?.querySelector('span');
    if (!label) return;
    // The stale label is not transient — it is the pill's whole remaining
    // purpose — so nothing is allowed to flash over it or restore past it.
    if (btn.getAttribute(STALE_ATTR) === '1') return;
    // Capture the resting label once. Reading it per flash meant a second
    // click inside the 1.5s window captured the *flashed* text as the
    // original and left the pill stuck on it.
    if (!btn.dataset.mdlRestingLabel) btn.dataset.mdlRestingLabel = label.textContent;
    label.textContent = text;
    clearTimeout(flashTimers.get(btn));
    flashTimers.set(btn, setTimeout(() => {
      flashTimers.delete(btn);
      if (btn.getAttribute(STALE_ATTR) === '1') return;
      label.textContent = btn.dataset.mdlRestingLabel;
    }, 1500));
  }

  function isManifestUrl(url) {
    if (!url || typeof url !== 'string') return false;
    return /\.m3u8(\?|$)/i.test(url) || /\.mpd(\?|$)/i.test(url);
  }

  function groupKeyForManifest(url) {
    try {
      const u = new URL(url, location.href);
      const dir = u.pathname.slice(0, u.pathname.lastIndexOf('/') + 1);
      return u.origin + dir;
    } catch {
      return url;
    }
  }

  // Deterministically resolves the manifest URL and CDN group key for a specific video.
  // Checks attributes on the video element itself, its child sources, its shadow host
  // (e.g. Reddit's <shreddit-player src="...">, <mux-player src="...">), and parent containers.
  function findManifestForVideo(video) {
    if (!video) return null;

    // 1. Tagged attribute on video element
    const taggedGroup = video.getAttribute?.('data-mdl-group');
    const taggedManifest = video.getAttribute?.('data-mdl-manifest');
    if (taggedGroup || taggedManifest) {
      return {
        groupKey: taggedGroup || (taggedManifest ? groupKeyForManifest(taggedManifest) : null),
        manifestUrl: taggedManifest || null,
      };
    }

    // 2. Direct src on video or currentSrc
    const vSrc = video.getAttribute?.('src');
    if (isManifestUrl(vSrc)) return { groupKey: groupKeyForManifest(vSrc), manifestUrl: vSrc };
    if (isManifestUrl(video.currentSrc)) return { groupKey: groupKeyForManifest(video.currentSrc), manifestUrl: video.currentSrc };

    // 3. Child <source> elements
    for (const s of video.querySelectorAll('source')) {
      const sSrc = s.src || s.getAttribute?.('src');
      if (isManifestUrl(sSrc)) return { groupKey: groupKeyForManifest(sSrc), manifestUrl: sSrc };
    }

    // 4. Shadow host hierarchy (e.g. <shreddit-player src="...">, <mux-player src="...">)
    let node = video;
    while (node) {
      const host = node.getRootNode?.()?.host;
      if (host) {
        const hostGroup = host.getAttribute?.('data-mdl-group');
        const hostManifest = host.getAttribute?.('src') || host.getAttribute?.('data-src') || host.getAttribute?.('stream-url') || host.getAttribute?.('data-mdl-manifest');
        if (isManifestUrl(hostManifest)) {
          return { groupKey: hostGroup || groupKeyForManifest(hostManifest), manifestUrl: hostManifest };
        }
        if (hostGroup) return { groupKey: hostGroup, manifestUrl: null };
        node = host;
      } else {
        break;
      }
    }

    // 5. Light-DOM ancestor container
    let parent = video.parentElement;
    while (parent && parent !== document.body && parent !== document.documentElement) {
      const pSrc = parent.getAttribute?.('src') || parent.getAttribute?.('data-src') || parent.getAttribute?.('data-manifest-url');
      if (isManifestUrl(pSrc)) return { groupKey: groupKeyForManifest(pSrc), manifestUrl: pSrc };
      parent = parent.parentElement;
    }

    return null;
  }

  // The one video on the page that could be playing a detected HLS/DASH
  // stream, or null when that isn't unambiguous. A stream plays through a
  // blob: (MediaSource) or straight from its playlist URL; a video playing a
  // plain file (a thumbnail preview, an ad clip) or nothing at all can't be
  // its consumer. So when exactly one latched video is stream-backed, the
  // page's detected streams are its streams, however many previews surround it.
  function soleStreamPlayer() {
    let sole = null;
    for (const video of latches.keys()) {
      const src = video.currentSrc || '';
      if (!src.startsWith('blob:') && !isManifestUrl(src)) continue;
      if (sole) return null;
      sole = video;
    }
    return sole;
  }

  function qualityLabel(url, el) {
    const resMatch = url.match(/(\d{3,4})p/i);
    if (resMatch) return `${resMatch[1]}p`;
    if (el?.getAttribute && el.getAttribute('label')) return el.getAttribute('label');
    if (el?.getAttribute && el.getAttribute('size')) return el.getAttribute('size');
    if (/\.m3u8(\?|$)/i.test(url)) return 'HLS stream';
    if (/\.mpd(\?|$)/i.test(url)) return 'DASH stream';
    return 'Original';
  }

  function collectSources(video) {
    const found = [];
    const seen = new Set();
    // A media file opened directly in a tab: the browser's stub page plays
    // the page URL itself, so here the page URL is the video.
    const pageIsMedia = /^(video|audio)\//i.test(document.contentType || '');
    const push = (url, label, isBlob) => {
      if (!url || seen.has(url)) return;
      // An empty src="" resolves to the page's own URL. That is the page,
      // not a video, and downloading it saves the page's HTML.
      if (!pageIsMedia && url.split('#')[0] === location.href.split('#')[0]) return;
      seen.add(url);
      // A player can play an HLS/DASH playlist straight from src. That URL is
      // a playlist, not a file: it downloads through the stream path, and its
      // HEAD reports the playlist's own text type and size, not the video's.
      if (isManifestUrl(url)) {
        found.push({
          url, label, unavailableReason: null, noSizeFetch: true,
          streamType: /\.mpd(\?|$)/i.test(url) ? 'dash' : 'hls',
        });
        return;
      }
      found.push({ url, label, unavailableReason: isBlob ? 'not directly downloadable' : null });
    };

    if (video.currentSrc) {
      push(video.currentSrc, qualityLabel(video.currentSrc, video), video.currentSrc.startsWith('blob:'));
    }
    video.querySelectorAll('source').forEach((s) => {
      if (s.src) push(s.src, qualityLabel(s.src, s), s.src.startsWith('blob:'));
    });

    // Inspect shadow host (e.g. Reddit's <shreddit-player packaged-media-json="...">)
    let node = video;
    while (node) {
      const host = node.getRootNode?.()?.host;
      if (host) {
        const pkgJson = host.getAttribute?.('packaged-media-json');
        if (pkgJson) {
          try {
            const data = JSON.parse(pkgJson);
            const perms = data?.playbackMp4s?.permutations || [];
            for (const p of perms) {
              const u = p.source?.url;
              const h = p.dimensions?.height;
              if (u && typeof u === 'string') {
                push(u, h ? `${h}p` : qualityLabel(u, null), false);
              }
            }
          } catch {}
        }
        node = host;
      } else {
        break;
      }
    }

    return found;
  }


  function filenameFromUrl(url) {
    try {
      const name = decodeURIComponent(new URL(url).pathname.split('/').pop() || '');
      return name || 'video';
    } catch {
      return 'video';
    }
  }

  // Returns the lowercase file extension (including dot, e.g. ".mp4") if the
  // URL's path ends in a known media container format, otherwise null.
  // Used to append the correct extension to a human-readable title filename
  // for direct (non-stream) downloads — the title has no extension, but the
  // CDN URL often does (e.g. /DASH_360.mp4, /video.webm, /clip.mov).
  const MEDIA_EXTS = /\.(mp4|m4v|webm|mov|avi|mkv|flv|wmv|ogg|ogv|mp3|m4a|aac|opus|wav|flac)(\?|#|$)/i;
  function extFromUrl(url) {
    if (!url || typeof url !== 'string') return null;
    try {
      const path = new URL(url).pathname;
      const m = path.match(MEDIA_EXTS);
      return m ? m[1].toLowerCase() : null;
    } catch {
      return null;
    }
  }


  function fmtBytes(bytes) {
    if (!bytes) return null;
    const units = ['B', 'KB', 'MB', 'GB'];
    let n = bytes, i = 0;
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(1)} ${units[i]}`;
  }

  // bandwidthBps is what HLS/DASH manifests declare per variant (bits/sec,
  // the sustained encode rate) — multiplying by the video's actual duration
  // gives an estimate close to the real file size without fetching a single
  // segment. Not exact (VBR content varies around that average), but far
  // better than the alternative: a HEAD request against the manifest URL
  // itself would just report the tiny playlist file's own size, which is
  // the exact bug this whole thing exists to avoid — see fetchMeta's
  // noSizeFetch check below.
  function estimateSizeFromBandwidth(bandwidthBps, durationSec) {
    if (!bandwidthBps || !durationSec || !Number.isFinite(durationSec)) return null;
    return Math.round((bandwidthBps / 8) * durationSec);
  }

  // Resolution, frame rate and codec as separate fields rather than one
  // joined string ("2160p60 · AV1") — the panel renders fps/codec as their
  // own pills now, so callers need them individually. Frame rate is only
  // surfaced when it's actually high (>30); tagging ordinary 24/25/30fps
  // content would just add a "30" pill to nearly every row for free.
  function variantLabel(v, showCodec) {
    return {
      res: v.height ? `${v.height}p` : (v.width ? `${v.width}w` : null),
      fps: v.fps && v.fps > 30 ? String(Math.round(v.fps)) : null,
      codec: (showCodec && v.codecFamily) ? v.codecFamily : null,
    };
  }

  // YouTube's googlevideo.com CDN throttles any URL missing `ratebypass=yes`
  // to ~500 kbps — shared across ALL connections, so 8 parallel segments are
  // no faster than 1. yt-dlp only adds ratebypass for muxed formats (itag=18
  // etc.); DASH video-only/audio-only streams come through without it.
  // We append it here on the JS side so no Swift rebuild is needed.
  function bypassGooglevideoThrottle(url) {
    if (!url || typeof url !== 'string') return url;
    try {
      if (!url.includes('googlevideo.com')) return url;
      if (url.includes('ratebypass=')) return url;
      const separator = url.includes('?') ? '&' : '?';
      return url + separator + 'ratebypass=yes';
    } catch {
      return url;
    }
  }

  function iconFor(url) {
    if (!url || typeof url !== 'string') return '🚫';
    const ext = (url.split('.').pop() || '').split('?')[0].toLowerCase();
    if (/^(mp4|mkv|webm|mov|avi|m3u8|mpd|ts)$/.test(ext)) return '🎬';
    if (/^(mp3|wav|flac|aac|m4a|ogg)$/.test(ext)) return '🎵';
    return '📄';
  }

  // Fetches real size + content-type via HEAD so the panel shows an
  // informed choice (name, type, size) rather than just a quality guess.
  // Best-effort: many CDNs block cross-origin HEAD from a page context via
  // CORS, so this fails silently and the row just shows "size unknown".
  async function fetchMeta(url) {
    try {
      const res = await fetch(url, { method: 'HEAD', mode: 'cors' });
      const len = res.headers.get('content-length');
      const type = res.headers.get('content-type');
      return { size: len ? parseInt(len, 10) : null, contentType: type };
    } catch {
      return { size: null, contentType: null };
    }
  }

  function makeButton() {
    const btn = document.createElement('div');
    btn.setAttribute('data-mdl-ui', '1');
    btn.setAttribute('data-mdl-latch', '1');
    Object.assign(btn.style, {
      position: 'fixed',
      zIndex: 2147483647,
      display: 'flex',
      alignItems: 'center',
      gap: '6px',
      padding: '6px 12px',
      borderRadius: '999px',
      background: 'rgba(20,20,24,0.92)',
      backdropFilter: 'blur(4px)',
      cursor: 'pointer',
      boxShadow: '0 2px 8px rgba(0,0,0,0.35)',
      transition: 'opacity 0.12s ease',
      opacity: '0',
      pointerEvents: 'none',
      whiteSpace: 'nowrap',
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
    });
    btn.innerHTML = `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
      <path d="M12 3v12m0 0l-4-4m4 4l4-4M4 19h16" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    </svg><span style="color:#fff;font-size:12px;font-weight:600;">Download video</span>`;
    document.documentElement.appendChild(btn);
    return btn;
  }

  function makePanel() {
    const panel = document.createElement('div');
    panel.setAttribute('data-mdl-ui', '1');
    panel.setAttribute('data-mdl-latch', '1');
    Object.assign(panel.style, {
      position: 'fixed',
      zIndex: 2147483647,
      minWidth: '220px',
      maxWidth: '300px',
      background: 'rgba(24,24,28,0.97)',
      backdropFilter: 'blur(8px)',
      borderRadius: '10px',
      boxShadow: '0 8px 24px rgba(0,0,0,0.45)',
      padding: '8px',
      display: 'none',
      overflowY: 'auto',
      overscrollBehavior: 'contain',
      fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
    });
    document.documentElement.appendChild(panel);
    return panel;
  }

  function qualityKey(src) {
    // Key on resolution + codec + fps together, not just the label — since
    // variantLabel() now returns these as separate fields (label itself is
    // just "1080p"), a plain label-based key would collapse different
    // codec/fps variants at the same resolution back into one row, exactly
    // the bug this key was introduced to fix in the first place. Genuine
    // duplicates (e.g. a multi-Period DASH manifest repeating its ladder)
    // still share identical values on all three fields, so they still
    // dedupe correctly here.
    if (src.label) {
      return [src.label, src.codec, src.fps].filter(Boolean).join('|').trim().toLowerCase();
    }
    return (src.url || '').trim().toLowerCase();
  }

  // Deduplicates qualities within the same delivery group and sorts descending by resolution.
  function sortGroupSources(sources) {
    const seen = new Map();
    for (const s of sources) {
      const k = qualityKey(s);
      if (!seen.has(k)) {
        seen.set(k, s);
      } else {
        const existing = seen.get(k);
        // Tie-breaker within the same group: prefer one with known sizeBytes
        if (!existing.sizeBytes && s.sizeBytes) {
          seen.set(k, s);
        }
      }
    }
    return Array.from(seen.values()).sort((a, b) => {
      // Keep unavailable (e.g. unhooked blob) rows at the bottom
      if (!!a.unavailableReason !== !!b.unavailableReason) {
        return a.unavailableReason ? 1 : -1;
      }
      // Sort by resolution height descending (e.g. 1088p > 726p > 544p > 408p > 332p)
      const aH = resolutionOf(a);
      const bH = resolutionOf(b);
      if (aH !== bH) return bH - aH;
      // Secondary tie-breaker: sizeBytes descending
      return (b.sizeBytes || 0) - (a.sizeBytes || 0);
    });
  }

  function createSectionHeader(title) {
    const header = document.createElement('div');
    header.textContent = title;
    Object.assign(header.style, {
      fontSize: '10px',
      fontWeight: '700',
      letterSpacing: '0.8px',
      color: '#8e8e96',
      textTransform: 'uppercase',
      padding: '8px 12px 4px 12px',
    });
    return header;
  }

  function createSectionDivider() {
    const divider = document.createElement('div');
    Object.assign(divider.style, {
      height: '1px',
      background: 'rgba(255, 255, 255, 0.08)',
      margin: '4px 8px',
    });
    return divider;
  }

  // Small rounded label used for codec/fps tags on a quality row ("AV1",
  // "60"). Kept as its own factory so every pill in the panel stays
  // visually consistent rather than drifting per call site.
  function createPill(text, color) {
    const pill = document.createElement('span');
    pill.textContent = text;
    Object.assign(pill.style, {
      fontSize: '10px',
      fontWeight: '600',
      padding: '1px 6px',
      borderRadius: '4px',
      background: 'rgba(255, 255, 255, 0.1)',
      color: color || '#c9c9cf',
      letterSpacing: '0.2px',
    });
    return pill;
  }

  // Builds and sends the actual download request to the background script.
  // Kept as its own function rather than inlined in the row's click handler
  // — the payload logic below has enough moving parts (streamType,
  // audioTracks, pairedAudio, headers) that this project has been bitten
  // before by a field silently dropped when similar logic existed in two
  // places (see retryFailed's customHeaders fix), so it stays isolated even
  // with a single caller today.
  function sendVideoDownload(src, pageUrl, video) {
    const rawTitle = src.filename || (video ? titleForVideo(video) : cleanedPageTitle());
    // An embedded player frame usually has no title of its own, and a
    // cross-origin frame can't read the page around it. The tab's title is
    // the page the user is looking at, so the background supplies it.
    if (!rawTitle && window !== window.top) {
      const sent = safeSendMessage({ type: 'getTabTitle' }, (response) => {
        void chrome.runtime.lastError;
        sendVideoDownloadNamed(src, pageUrl, response?.title);
      });
      if (sent) return;
    }
    sendVideoDownloadNamed(src, pageUrl, rawTitle);
  }

  function sendVideoDownloadNamed(src, pageUrl, rawTitle) {
    const downloadUrl = bypassGooglevideoThrottle(src.url);
    const baseTitle = cleanTitleForFilename(rawTitle);
    let filename;
    if (baseTitle) {
      if (!src.streamType) {
        const urlExt = extFromUrl(src.url);
        const alreadyHasExt = urlExt && baseTitle.toLowerCase().endsWith('.' + urlExt);
        filename = (urlExt && !alreadyHasExt) ? `${baseTitle}.${urlExt}` : baseTitle;
      } else {
        filename = baseTitle;
      }
    }

    safeSendMessage({
      type: 'downloadRequest',
      payload: {
        urls: [downloadUrl],
        referrer: pageUrl,
        filename: filename || undefined,
        segmentCount: 8,
        ...(src.streamType ? { streamType: src.streamType } : {}),
        ...(src.representationId ? { representationId: src.representationId } : {}),
        ...(src.bandwidth ? { bandwidth: src.bandwidth } : {}),
        ...(src.audioTracks ? { audioTracks: src.audioTracks } : {}),
        ...(src.ext ? { ext: src.ext } : {}),
        ...(src.headers ? { headers: src.headers } : {}),
        ...(src.pairedAudio ? {
          pairedAudio: {
            ...src.pairedAudio,
            url: bypassGooglevideoThrottle(src.pairedAudio.url),
          }
        } : {}),
      },
      source: 'video-latch',
    });
  }

  function createSourceRow(src, pageUrl, video, panel) {
    const unavailable = !!src.unavailableReason;
    const row = document.createElement('div');
    Object.assign(row.style, {
      display: 'flex',
      alignItems: 'center',
      gap: '12px',
      padding: '8px 12px',
      borderRadius: '6px',
      cursor: unavailable ? 'default' : 'pointer',
      opacity: unavailable ? '0.5' : '1',
      transition: 'background 0.15s ease',
    });

    const icon = document.createElement('span');
    icon.textContent = iconFor(src.url);
    Object.assign(icon.style, { fontSize: '18px', flexShrink: '0' });

    const info = document.createElement('div');
    Object.assign(info.style, { display: 'flex', flexDirection: 'column', gap: '2px', minWidth: '0', flex: '1' });

    const nameRow = document.createElement('div');
    Object.assign(nameRow.style, {
      display: 'flex',
      alignItems: 'center',
      flexWrap: 'wrap',
      rowGap: '4px',
      gap: '6px',
      color: '#fff',
      fontSize: '13px',
      fontWeight: '600',
    });

    const labelText = document.createElement('span');
    labelText.textContent = src.label; // e.g. "1080p", "1088p", "1080p60"
    nameRow.appendChild(labelText);

    // Codec / fps pills — only present on parsed HLS/DASH variants (see
    // variantLabel in the manifest-merge path); DOM-scanned direct sources
    // never set these, so the pills simply don't render for them.
    if (src.codec) nameRow.appendChild(createPill(src.codec, '#c9c9cf'));
    if (src.fps) nameRow.appendChild(createPill(src.fps, '#c9c9cf'));

    // Format badge: DIRECT vs DASH / HLS
    if (!unavailable) {
      const badge = document.createElement('span');
      if (src.streamType) {
        badge.textContent = src.streamType.toUpperCase();
        Object.assign(badge.style, {
          fontSize: '9px',
          fontWeight: '700',
          padding: '1px 4px',
          borderRadius: '3px',
          background: 'rgba(255, 170, 0, 0.2)',
          color: '#ffb340',
          letterSpacing: '0.4px',
        });
      } else {
        badge.textContent = 'DIRECT';
        Object.assign(badge.style, {
          fontSize: '9px',
          fontWeight: '700',
          padding: '1px 4px',
          borderRadius: '3px',
          background: 'rgba(91, 155, 255, 0.2)',
          color: '#6bb1ff',
          letterSpacing: '0.4px',
        });
      }
      nameRow.appendChild(badge);
    }

    const metaRow = document.createElement('div');
    const sizeText = src.sizeBytes
      ? (src.streamType ? `~${fmtBytes(src.sizeBytes)}` : fmtBytes(src.sizeBytes))
      : 'size unknown';
    const typeName = src.streamType ? src.streamType.toUpperCase() : 'MP4';
    metaRow.textContent = unavailable
      ? src.unavailableReason
      : `${typeName} · ${sizeText}`;
    Object.assign(metaRow.style, { color: '#9a9aa2', fontSize: '11.5px' });

    info.appendChild(nameRow);
    if (metaRow.textContent) info.appendChild(metaRow);

    const action = document.createElement('div');
    action.innerHTML = unavailable ? '' : `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M12 3v12m0 0l-4-4m4 4l4-4M4 19h16" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
    Object.assign(action.style, { 
      color: '#5b9bff', 
      display: 'flex',
      alignItems: 'center',
      opacity: '0',
      transition: 'opacity 0.15s ease',
      flexShrink: '0',
    });

    row.onmouseenter = () => { 
      if (!unavailable) {
        row.style.background = 'rgba(255,255,255,0.08)'; 
        action.style.opacity = '1';
      }
    };
    row.onmouseleave = () => { 
      row.style.background = 'transparent'; 
      action.style.opacity = '0';
    };

    row.appendChild(icon);
    row.appendChild(info);
    row.appendChild(action);

    if (!unavailable) {
      if (!src.sizeBytes && !src.noSizeFetch && src.url && typeof src.url === 'string' && src.url !== '#') {
        fetchMeta(src.url).then(({ size, contentType }) => {
          const newSizeText = fmtBytes(size);
          const ext = extFromUrl(src.url)?.toUpperCase();
          const typeText = contentType ? contentType.split(';')[0].replace(/^video\//, '').toUpperCase() : (ext || typeName);
          // A web page is never the video: whatever the element pointed at
          // answered with HTML (a login wall, an error page, the page itself).
          if (/^text\/html\b/i.test(contentType || '')) {
            src.notMedia = true;
            metaRow.textContent = 'not a video file';
            row.style.opacity = '0.5';
            row.style.cursor = 'default';
            action.innerHTML = '';
            return;
          }
          metaRow.textContent = `${typeText} · ${newSizeText || 'size unknown'}`;
        });
      }

      row.addEventListener('click', () => {
        if (src.notMedia) return;
        sendVideoDownload(src, pageUrl, video);
        action.innerHTML = '<span style="font-size: 12px; font-weight: 600;">Sent ✓</span>';
        action.style.opacity = '1';
        setTimeout(() => { panel.style.display = 'none'; }, 500);
      });
    }

    return row;
  }

  // Extracts the resolution height from a row's label ("1080p" -> 1080).
  // Shared by sortGroupSources' ordering and pickBest's ranking below.
  function resolutionOf(src) {
    return parseInt((src.label || '').match(/(\d+)p/i)?.[1] || '0', 10);
  }

  function renderPanel(panel, sources, pageUrl, video) {
    panel.innerHTML = '';
    const hasWorkingOption = sources.some((s) => !s.unavailableReason);
    if (hasWorkingOption) sources = sources.filter((s) => !s.unavailableReason);
    if (sources.length === 0) {
      const empty = document.createElement('div');
      empty.textContent = 'No downloadable source found yet';
      Object.assign(empty.style, { color: '#9a9aa2', fontSize: '13px', padding: '12px 10px' });
      panel.appendChild(empty);
      return;
    }

    const directSources = sortGroupSources(sources.filter((s) => !s.streamType));
    const streamSources = sortGroupSources(sources.filter((s) => !!s.streamType));
    const hasBoth = directSources.length > 0 && streamSources.length > 0;

    if (directSources.length > 0) {
      if (hasBoth) {
        panel.appendChild(createSectionHeader('Direct Downloads'));
      }
      directSources.forEach((src) => {
        panel.appendChild(createSourceRow(src, pageUrl, video, panel));
      });
    }

    if (streamSources.length > 0) {
      if (hasBoth) {
        panel.appendChild(createSectionDivider());
        panel.appendChild(createSectionHeader('Adaptive Streams'));
      }
      streamSources.forEach((src) => {
        panel.appendChild(createSourceRow(src, pageUrl, video, panel));
      });
    }
  }

  function positionButton(btn, video) {
    const rect = video.getBoundingClientRect();
    if (rect.width < 80 || rect.height < 60) {
      // Too small to be a real player (thumbnail, icon, etc.) — don't latch.
      btn.style.opacity = '0';
      btn.style.pointerEvents = 'none';
      return false;
    }
    // Sits just OUTSIDE the video's frame, above the top-right corner —
    // never overlaps the player or any of its own controls. If the video's
    // top edge is right at the viewport top (no room above), fall back to
    // just inside instead of clipping off-screen.
    const btnHeight = btn.offsetHeight || 28;
    const gap = 0;
    const spaceAbove = rect.top;
    const top = spaceAbove > btnHeight + gap ? rect.top - btnHeight - gap : rect.top + gap;
    btn.style.top = `${top}px`;
    btn.style.right = `${window.innerWidth - rect.right}px`;
    btn.style.left = 'auto';
    return true;
  }

  function positionPanel(panel, btn) {
    const btnRect = btn.getBoundingClientRect();
    panel.style.top = `${btnRect.bottom + 2}px`;
    panel.style.right = `${window.innerWidth - btnRect.right}px`;
    panel.style.left = 'auto';
    // Recomputed on every open/re-render rather than fixed in makePanel,
    // because it depends on where the button currently is — the pill tracks
    // the video, so the room beneath it changes with scroll, resize and
    // player-size changes. Without this a full quality ladder runs off the
    // bottom of the viewport with its last rows unreachable, since the panel
    // is position:fixed and doesn't scroll with the page.
    const available = window.innerHeight - btnRect.bottom - 12;
    panel.style.maxHeight = `${Math.max(160, available)}px`;
  }

  function latch(video) {
    if (video.hasAttribute(LATCHED_ATTR)) return;
    video.setAttribute(LATCHED_ATTR, '1');

    const btn = makeButton();
    const panel = makePanel();

    // Network sniffing (detectedMediaByTab in background.js) watches the
    // whole tab, not this specific <video> — on a page that autoplays more
    // than one video at once (Pinterest's related-pins feed is exactly this:
    // the pin you're on plus nearby recommended pins all playing previews
    // simultaneously), the panel would otherwise mix in a second, completely
    // unrelated video's quality ladder alongside this one's.
    //
    // Fixed with a deterministic signal instead of a time-based guess: CDNs
    // overwhelmingly colocate one video's renditions (master, every quality
    // variant, its audio track) under one shared directory — confirmed
    // against a real capture, not assumed (see groupKeyForManifest's doc
    // comment in background.js).
    let hideTimer = null;
    // Set by the background worker only for the one player chosen to
    // represent the freshly resolved manifest. Keeping this local prevents a
    // tab-level network event from making every autoplaying thumbnail show a
    // permanent download control.
    let streamResolvedForVideo = false;
    const show = () => {
      clearTimeout(hideTimer);
      const ok = positionButton(btn, video);
      if (!ok) return;
      btn.style.opacity = '1';
      btn.style.pointerEvents = 'auto';
    };
    const hide = () => {
      clearTimeout(hideTimer);
      btn.style.opacity = '0';
      btn.style.pointerEvents = 'none';
    };
    const scheduleHide = () => {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => {
        if (panel.style.display === 'block') return; // panel open, keep latch alive
        hide();
      }, 300);
    };

    // Re-evaluates whether this video currently deserves a persistent pill.
    // Called on SPA navigation and on player resize: YouTube reuses the same
    // <video> element across watch→watch and watch→home navigations, so
    // latch() never runs again and this is the only thing that can correct
    // the pill's state afterwards.
    const refresh = () => {
      const persistent = wantsPersistentLatch(video) || streamResolvedForVideo;
      const wasPersistent = btn.getAttribute(PERSISTENT_ATTR) === '1';
      btn.setAttribute(PERSISTENT_ATTR, persistent ? '1' : '0');
      if (persistent) {
        applyCompactStyle(btn);
        show();
      } else if (wasPersistent) {
        // Navigated off a watch page. YouTube reuses the same <video>, so
        // this is the only thing that can take the pill back down again.
        panel.style.display = 'none';
        hide();
      }
    };

    const setStreamResolved = (resolved) => {
      streamResolvedForVideo = resolved;
      refresh();
    };
    latches.set(video, { btn, panel, refresh, setStreamResolved, show, scheduleHide });

    // Hover reveal stays the behaviour for every non-persistent video (all
    // non-YouTube sites, plus YouTube thumbnail previews). mouseleave is only
    // wired up for those — a persistent pill must not vanish on mouseout.
    video.addEventListener('mouseenter', show);
    video.addEventListener('mousemove', show);
    video.addEventListener('mouseleave', () => {
      if (btn.getAttribute(PERSISTENT_ATTR) === '1') return;
      scheduleHide();
    });
    btn.addEventListener('mouseenter', () => clearTimeout(hideTimer));
    btn.addEventListener('mouseleave', () => {
      if (btn.getAttribute(PERSISTENT_ATTR) === '1') return;
      scheduleHide();
    });

    btn.addEventListener('click', async (e) => {
      e.stopPropagation();

      // An already-relabelled pill has exactly one job left. scan() normally
      // relabels before the user ever clicks, so this is usually the first
      // click they make on a stale pill.
      if (btn.getAttribute(STALE_ATTR) === '1') {
        window.location.reload();
        return;
      }
      // Not relabelled yet (an idle tab that hasn't scanned since the context
      // died): convert on this click rather than firing a call that throws.
      if (!isExtensionAlive()) {
        markLatchStale(latches.get(video) || { btn, panel });
        return;
      }

      // YouTube (and future ytdlp-strategy sites): no panel, no fetch, no
      // wait. Hand the page URL to the app and let its own quality picker
      // (AddDownloadsView) take it from there.
      if (currentStrategy() === 'ytdlp') {
        sendYouTubeToApp(window.location.href, btn);
        return;
      }

      const willOpen = panel.style.display !== 'block';
      panel.style.display = willOpen ? 'block' : 'none';
      if (!willOpen) return;

      // Render immediately with whatever the DOM already shows — no wait,
      // no round-trip, matches the ytdlp-strategy branch's "no forced stop"
      // philosophy even though this branch does have more to fetch.
      const domSources = collectSources(video);
      renderPanel(panel, domSources, window.location.href, video);
      positionPanel(panel, btn);

      // Deterministically resolve the manifest and groupKey for this specific video.
      // Checks video attributes, child sources, shadow host (<shreddit-player src="...">),
      // and ancestor containers. Zero timestamp heuristics.
      const manifestInfo = findManifestForVideo(video);
      const isSingleVideoPage = latches.size <= 1 || soleStreamPlayer() === video;

      safeSendMessage({
        type: 'getDetectedMedia',
        groupKey: manifestInfo?.groupKey || undefined,
        manifestUrl: manifestInfo?.manifestUrl || undefined,
        isSingleVideoPage,
      }, (response) => {
        let detected = response?.media;
        if (!detected?.length) return;

        // Strict deterministic scoping:
        if (manifestInfo?.groupKey) {
          detected = detected.filter((m) => m.groupKey === manifestInfo.groupKey);
        } else if (manifestInfo?.manifestUrl) {
          detected = detected.filter((m) => m.url === manifestInfo.manifestUrl);
        } else if (!isSingleVideoPage) {
          // On a multi-video page where this video could not be deterministically
          // identified, NEVER show other videos' manifests!
          detected = [];
        }

        if (!detected.length) return;


        const seen = new Set(domSources.map((s) => s.url));
        const merged = domSources.slice();

        // Every audio URL already referenced by some variant's audioTracks
        // (see parseHlsManifest) — collected up front, across every detected
        // manifest, since a page can have more than one video/audio group on
        // it. Used below to suppress a redundant standalone row for a
        // manifest that turns out to just be one of these, already being
        // fetched and merged in automatically the moment its matching video
        // row is clicked.
        const attachedAudioUrls = new Set();
        for (const m of detected) {
          if (!m.variants?.length) continue;
          for (const v of m.variants) {
            for (const a of (v.audioTracks || [])) attachedAudioUrls.add(a.url);
          }
        }

        for (const m of detected) {
          if (seen.has(m.url)) {
            // The DOM already listed this playlist as one opaque row; its
            // parsed quality ladder replaces that row.
            const placeholder = merged.findIndex((r) => r.url === m.url && r.streamType);
            if (!m.variants?.length || placeholder < 0) continue;
            merged.splice(placeholder, 1);
          }
          seen.add(m.url);

          if (!m.variants?.length) {
            // A manifest that isn't its own master playlist is very likely a
            // piece of one that already got attached above — most commonly
            // the separate audio track for an HLS variant group. Downloading
            // it directly would give audio with no video, which nobody wants
            // when the matching video row already fetches and merges it in
            // automatically. Skip it entirely rather than showing a
            // confusing, unlabeled "HLS stream" row for something that isn't
            // actually a separate choice.
            if (attachedAudioUrls.has(m.url)) continue;
            // Parsing failed or found nothing to rank (fetch error, not a
            // master playlist, unsupported shape) — fall back to the single
            // opaque row this always showed before manifest parsing existed.
            merged.push({
              url: m.url,
              label: qualityLabel(m.url, null),
              sizeBytes: null,
              noSizeFetch: true, // still a manifest URL even though we couldn't parse it — same HEAD-would-lie problem applies
              unavailableReason: null,
              // Tag with stream kind so the app routes through StreamDownloader
              // rather than treating this as a plain byte-range download.
              streamType: m.kind,
            });
            continue;
          }

          // The <video> element is the better duration source when it has
          // one, since it reflects what's actually loaded, but it reports NaN
          // until metadata arrives — and a DASH VOD manifest states the
          // presentation duration outright, so the fallback covers the case
          // where the panel is opened before playback has really started.
          const durationSec = Number.isFinite(video.duration) ? video.duration : m.durationSec;
          // Codec only earns a slot in the label when the ladder actually
          // mixes codecs; otherwise every row would carry the same redundant
          // "H.264" and squeeze out the numbers that distinguish them.
          const showCodec = new Set(m.variants.map((v) => v.codecFamily).filter(Boolean)).size > 1;

          for (const v of m.variants) {
            // exactUrl rows point at a URL that really does select this one
            // quality: an HLS variant playlist, or a DASH Representation whose
            // resolved <BaseURL> is a single complete file. The rest can only
            // be pointed at the master manifest (which is what the parser
            // already set v.url to), so they carry an "auto quality" note —
            // the ladder shows what the stream offers, while the note stays
            // honest that clicking one hands off the manifest and lets the
            // downloader choose. That caveat lives in the size line rather
            // than the title because the title is fixed-width and ellipsised,
            // and appending to it produced cut-off text like
            // "14932 kbps (au…" that read as a bug rather than a label.
            //
            // Only exact rows go through `seen`. Non-exact ones all share the
            // manifest URL, so de-duplicating them by URL would collapse the
            // whole ladder back into the single row this is fixing — `seen`
            // is here to avoid re-listing something the DOM scan already
            // found, and the manifest URL itself was added above.
            if (v.exactUrl) {
              if (seen.has(v.url)) continue;
              seen.add(v.url);
            }
            const vLabel = variantLabel(v, showCodec);
            merged.push({
              url: v.url,
              label: vLabel.res || qualityLabel(v.url, null),
              codec: vLabel.codec,
              fps: vLabel.fps,
              sizeBytes: estimateSizeFromBandwidth(v.bandwidthBps, durationSec),
              noSizeFetch: true, // a HEAD here would report the manifest/sub-playlist's own tiny text size, not the video's — see estimateSizeFromBandwidth
              note: v.exactUrl ? null : 'auto quality',
              unavailableReason: null,
              // Stream routing metadata for the native app:
              // HLS rows: always streamType='hls' (variant playlist needs segment download)
              // DASH exact rows (single file): no streamType → byte-range engine
              // DASH non-exact rows: streamType='dash' + representationId + bandwidth
              ...(m.kind === 'hls' ? {
                streamType: 'hls',
                // Split-audio candidates for this specific variant's AUDIO
                // group, if it has one — see parseHlsManifest in
                // background.js. Absent (undefined via the spread) for the
                // common combined-stream case, where the video's own
                // segments already carry sound and there's nothing to merge.
                ...(v.audioTracks?.length ? { audioTracks: v.audioTracks } : {}),
              } :
                  m.kind === 'dash' && !v.exactUrl ? {
                    streamType: 'dash',
                    ...(v.representationId ? { representationId: v.representationId } : {}),
                    ...(v.bandwidthBps ? { bandwidth: v.bandwidthBps } : {}),
                  } : {}),
            });
          }
        }

        // nothing new (a replaced placeholder can leave the count unchanged)
        if (merged.length === domSources.length && merged.every((r, i) => r === domSources[i])) return;
        renderPanel(panel, merged, window.location.href, video);
        positionPanel(panel, btn);
      });
    });

    const reposition = () => {
      if (btn.getAttribute(PERSISTENT_ATTR) === '1') {
        // show() rather than a bare positionButton: on a cold load the player
        // often has a 0x0 box when latch() first runs, so positionButton
        // refuses and leaves the pill hidden. Re-asserting visibility here is
        // what actually brings it up once the player has real dimensions.
        show();
      } else if (btn.style.opacity === '1') {
        positionButton(btn, video);
      }
      if (panel.style.display === 'block') positionPanel(panel, btn);
    };
    window.addEventListener('scroll', reposition, true);
    window.addEventListener('resize', reposition);

    // YouTube resizes its player on theater toggle, mini-player, description
    // expand and sidebar collapse — none of which fire scroll or resize — so
    // the pill would drift out of place without observing the video box
    // itself. Observing the <video> rather than the player container because
    // that's the element positionButton actually measures.
    if (typeof ResizeObserver === 'function') {
      new ResizeObserver(reposition).observe(video);
    }

    document.addEventListener('click', (e) => {
      if (panel.style.display === 'block' && !panel.contains(e.target) && e.target !== btn) {
        panel.style.display = 'none';
      }
    });

    refresh();
  }

  // A slightly more compact pill for the persistent YouTube latch. The gap
  // between YouTube's fixed masthead and the top of the player is only about
  // 24px; the default pill is taller than that, so positionButton would fall
  // back to tucking it *inside* the player's top-right corner (over the
  // video) instead of sitting above it. Trimming the padding brings it under
  // that budget so it lands cleanly in the gap, clear of both the masthead
  // and the video frame.
  function applyCompactStyle(btn) {
    Object.assign(btn.style, { padding: '4px 10px' });
    const label = btn.querySelector('span');
    if (label) label.style.fontSize = '11.5px';
  }

  // Watch→watch, watch→home and home→watch are all SPA navigations on
  // YouTube: no page load, so content scripts never re-run. yt-navigate-finish
  // is YouTube's own signal for "the new page is live"; the href poll is the
  // fallback for anything it misses (and for youtu.be redirects), since the
  // extension has no webNavigation permission to observe this properly.
  //
  // YouTube-only: refresh() only has work to do for persistent pills, which
  // only exist here, and elsewhere the MutationObserver already covers newly
  // added <video> elements. No reason to leave a timer running on every page
  // on the web.
  function watchForNavigation() {
    if (!isYouTubeHost()) return;
    let lastHref = location.href;
    const onNavigated = () => {
      if (location.href === lastHref) return;
      lastHref = location.href;
      scan();
      latches.forEach(({ refresh }) => refresh());
    };
    document.addEventListener('yt-navigate-finish', () => {
      lastHref = null; // force onNavigated to act even if href already updated
      onNavigated();
    });
    setInterval(onNavigated, 700);
  }

  // A resolved manifest belongs to the tab, not a DOM node. Choose one
  // plausible player rather than showing permanent controls on every preview:
  // a currently-playing visible video wins; otherwise the largest visible
  // video is the least surprising fallback.
  let resolvedStreamPageURL = null;
  let resolvedStreamGroupKey = null;

  function surfaceResolvedStreamLatch() {
    if (currentStrategy() !== 'sniff') return;
    const viewportCandidates = [...latches.entries()]
      .filter(([video]) => {
        const rect = video.getBoundingClientRect();
        return rect.width >= 80 && rect.height >= 60
          && rect.bottom > 0 && rect.right > 0
          && rect.top < window.innerHeight && rect.left < window.innerWidth;
      })
      .sort(([a], [b]) => {
        const aPlaying = !a.paused && !a.ended ? 1 : 0;
        const bPlaying = !b.paused && !b.ended ? 1 : 0;
        if (aPlaying !== bPlaying) return bPlaying - aPlaying;
        const ar = a.getBoundingClientRect();
        const br = b.getBoundingClientRect();
        return (br.width * br.height) - (ar.width * ar.height);
      });

    // 1. If we know which stream group just resolved, check if an active player
    //    matches that stream group deterministically.
    let winner = null;
    if (resolvedStreamGroupKey) {
      const match = viewportCandidates.find(([video]) => {
        const mInfo = findManifestForVideo(video);
        return (mInfo && mInfo.groupKey === resolvedStreamGroupKey) ||
               video.getAttribute('data-mdl-group') === resolvedStreamGroupKey;
      });
      if (match) winner = match[0];
    }
    // 2. Otherwise only an unambiguous owner: the page's single video, or
    //    its single stream-backed one (see soleStreamPlayer).
    if (!winner && latches.size === 1) {
      winner = viewportCandidates[0]?.[0];
    }
    if (!winner) winner = soleStreamPlayer();
    if (!winner) return;

    for (const [video, latchState] of latches) {
      // Keep YouTube's existing persistent watch-page behavior untouched.
      if (!wantsPersistentLatch(video)) {
        latchState.setStreamResolved(video === winner);
      }
    }

  }

  function scan() {
    // Cheapest place to notice the context died: this is already coalesced to
    // one call per frame and runs on every DOM mutation and SPA navigation, so
    // in practice the pill relabels itself well before the user clicks it.
    // Bailing out also stops an orphaned page re-latching videos forever.
    if (!isExtensionAlive()) {
      markAllLatchesStale();
      return;
    }
    if (resolvedStreamPageURL && resolvedStreamPageURL !== location.href) {
      resolvedStreamPageURL = null;
      resolvedStreamGroupKey = null;
      for (const [video, latchState] of latches) {
        if (!wantsPersistentLatch(video)) latchState.setStreamResolved(false);
      }
    }
    document.querySelectorAll('video').forEach(latch);
    // Second pass: pierce open shadow roots to find videos the flat query missed.
    // Lightweight: only walks elements that actually host a shadow root, and
    // latch() is a no-op (returns immediately) for already-latched videos.
    querySelectorAllDeep('video').forEach(latch);
    if (resolvedStreamPageURL === location.href) surfaceResolvedStreamLatch();
  }

  // Coalesced so a mutation storm costs one sweep per frame instead of one
  // per batch. YouTube mutates the DOM more or less continuously (player
  // chrome, progress bar, sidebar hydration), and scan() walks every <video>
  // on the page, so calling it per batch is measurably expensive.
  let scanQueued = false;
  function scheduleScan() {
    if (scanQueued) return;
    scanQueued = true;
    requestAnimationFrame(() => {
      scanQueued = false;
      scan();
    });
  }

  scan();

  // ── Shadow DOM: capture-phase media event listeners ────────────────────────
  // These listeners catch <video> elements that are in the LIGHT DOM of a
  // custom element host — i.e. passed in via a <slot> (e.g. Media Chrome's
  // <slot name="media">). In that case the <video> is in the page's light DOM
  // and its events propagate normally to window.
  //
  // NOTE: Per WHATWG HTML § 4.8.12 + DOM § 2.9, native media events have
  // composed:false and bubbles:false, so they DO NOT cross shadow boundaries.
  // A <video> entirely inside a shadow root (e.g. inside shreddit-player's
  // shadowRoot) will NOT trigger this listener. Those videos are found by the
  // querySelectorAllDeep() call in scan() instead.
  //
  // The listeners are still useful for:
  //   1. Slotted <video> (light DOM) in custom player shells
  //   2. Component authors that re-dispatch with { composed: true }
  //   3. Any future browser change toward composed media events
  //
  // scheduleScan() rather than latch(video) directly — see earlier comment
  // about winner-election correctness on Reddit feeds.
  for (const eventName of ['play', 'loadedmetadata']) {
    window.addEventListener(eventName, (event) => {
      const path = event.composedPath();
      const video = path.find((el) => el instanceof HTMLVideoElement);
      if (video && !video.hasAttribute(LATCHED_ATTR)) {
        scheduleScan();
      }
    }, true);
  }

  watchForNavigation();
  // The background worker emits this only after it has fetched and parsed a
  // detected HLS/DASH manifest. That turns the latch from a hover discovery
  // affordance into an immediately visible "download is ready" control.
  chrome.runtime.onMessage.addListener((message) => {
    if (message?.type !== 'streamManifestResolved') return;
    resolvedStreamPageURL = location.href;
    resolvedStreamGroupKey = message?.payload?.groupKey || null;
    scheduleScan();
  });

  // When media-hook.js tags a video with data-mdl-group in the main world,
  // it fires this event. Schedule a scan so latch state updates immediately.
  window.addEventListener('__mdl_video_associated__', () => {
    scheduleScan();
  });
  new MutationObserver(scheduleScan).observe(document.documentElement, { childList: true, subtree: true });

  // ── Overlay-tolerant hover detection ────────────────────────────────────
  // Many sites (Reddit, Instagram, TikTok) place transparent <div> overlays
  // over <video> for click-to-pause/like gestures. These block mouseenter
  // from ever reaching the <video>. Instead of fighting each site's overlay
  // structure, check globally whether the mouse is within any latched video's
  // bounding rect, regardless of which element the browser considers "hovered".
  let hoverThrottleTimer = null;
  document.addEventListener('mousemove', (e) => {
    if (hoverThrottleTimer) return;
    hoverThrottleTimer = setTimeout(() => { hoverThrottleTimer = null; }, 80);

    for (const [video, latchState] of latches) {
      if (latchState.btn.getAttribute(PERSISTENT_ATTR) === '1') continue;
      const rect = video.getBoundingClientRect();
      if (rect.width < 80 || rect.height < 60) continue;
      const insideVideo = e.clientX >= rect.left && e.clientX <= rect.right
                       && e.clientY >= rect.top && e.clientY <= rect.bottom;
      if (insideVideo) {
        latchState.show();
      } else if (latchState.btn.style.opacity === '1') {
        const btnRect = latchState.btn.getBoundingClientRect();
        const insideBtn = e.clientX >= btnRect.left && e.clientX <= btnRect.right
                       && e.clientY >= btnRect.top && e.clientY <= btnRect.bottom;
        if (!insideBtn) {
          latchState.scheduleHide();
        }
      }
    }
  });
})();
