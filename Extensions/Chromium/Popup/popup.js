const NATIVE_HOST = 'io.github.thedynamicpunk.convoy.native';
// The Firefox build declares a gecko section in its manifest; Chrome's has none.
const IS_FIREFOX = Boolean(chrome.runtime.getManifest().browser_specific_settings?.gecko);

const captureToggle = document.getElementById('captureToggle');
const captureText = document.getElementById('captureText');
const statusDot = document.getElementById('statusDot');
const statusText = document.getElementById('statusText');
const openBtn = document.getElementById('openBtn');
const cookieToggle = document.getElementById('cookieToggle');

// ── Master switch ──────────────────────────────────────────────────────────
// Read by background.js (download capture, shortcut) and video-latch.js
// (latch visibility). Absent means on.

function showCapture(enabled) {
  captureToggle.checked = enabled;
  captureText.textContent = enabled ? 'Capturing downloads'
    : IS_FIREFOX ? 'Off — the browser handles downloads' : 'Off — Chrome handles downloads';
}

chrome.storage.local.get('captureEnabled', ({ captureEnabled }) => {
  showCapture(captureEnabled !== false);
});

captureToggle.addEventListener('change', () => {
  chrome.storage.local.set({ captureEnabled: captureToggle.checked });
  showCapture(captureToggle.checked);
});

// ── App status ─────────────────────────────────────────────────────────────
// ping → host → IPC server. Any failure = "not running".
// Two error classes:
//   • host not found  — manifest not registered; native messaging unusable.
//   • everything else — host exists but app not running; use normal path.

let opening = false;
let hostNotInstalled = false;

// Chrome: "Specified native messaging host not found."
// Firefox: "No such native application …"
function isHostNotFoundError(msg) {
  return /not found|no such native/i.test(msg || '');
}

function showStatus(running, notInstalled) {
  hostNotInstalled = !!notInstalled;
  statusDot.className = 'dot ' + (running ? 'on' : 'off');
  if (running) {
    statusText.textContent = 'Connected to Convoy';
    opening = false;
  } else if (notInstalled) {
    statusText.textContent = 'Finish setup in the Convoy app';
  } else {
    statusText.textContent = opening ? 'Opening Convoy…' : 'Convoy isn\u2019t running';
  }
  openBtn.hidden = running;
  openBtn.textContent = notInstalled ? 'Open Convoy' : 'Open';
  openBtn.disabled = opening && !notInstalled;
}

function checkStatus() {
  chrome.runtime.sendNativeMessage(NATIVE_HOST, { type: 'ping' }, (response) => {
    const err = chrome.runtime.lastError;
    if (err && isHostNotFoundError(err.message)) {
      showStatus(false, true);
    } else {
      showStatus(!err && response?.appRunning === true, false);
    }
  });
}

// Open button: routed through the background worker (survives popup close and
// replays a pending download). When the host is missing, bypass the worker —
// native messaging is unavailable — and open convoy://settings/browser directly.
openBtn.addEventListener('click', () => {
  if (hostNotInstalled) {
    chrome.tabs.create({ url: 'convoy://settings/browser' });
    window.close();
    return;
  }
  opening = true;
  showStatus(false, false);
  setTimeout(() => { opening = false; checkStatus(); }, 12000);
  chrome.runtime.sendMessage({ type: 'openConvoyApp' });
});

checkStatus();
setInterval(checkStatus, 2000);

// ── Cookies ────────────────────────────────────────────────────────────────
// "cookies" is optional, and chrome.permissions.request() only resolves from
// a user gesture on an extension page — which is why this control lives here
// rather than being requested from the service worker when a download needs it.

chrome.permissions.contains({ permissions: ['cookies'] }, (granted) => {
  cookieToggle.checked = granted;
});

cookieToggle.addEventListener('change', async () => {
  const granted = cookieToggle.checked
    ? await chrome.permissions.request({ permissions: ['cookies'] })
    : !(await chrome.permissions.remove({ permissions: ['cookies'] }));
  // Chrome's own dialog decides this, not the click — reflect the result.
  cookieToggle.checked = granted;
});

// ── Extension settings ─────────────────────────────────────────────────────
// Chrome's own details page for this extension: site access, incognito,
// pinning, and the shortcut link. There is no separate options page.

// Firefox won't let an extension open about:addons, so its build has no such
// button; the toolbar icon's context menu has Manage Extension.
if (IS_FIREFOX) {
  document.getElementById('settingsBtn').style.display = 'none';
} else {
  document.getElementById('settingsBtn').addEventListener('click', () => {
    chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` });
    window.close();
  });
}
