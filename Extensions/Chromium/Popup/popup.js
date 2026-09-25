const NATIVE_HOST = 'io.github.thedynamicpunk.convoy.native';

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
  captureText.textContent = enabled ? 'Capturing downloads' : 'Off — Chrome handles downloads';
}

chrome.storage.local.get('captureEnabled', ({ captureEnabled }) => {
  showCapture(captureEnabled !== false);
});

captureToggle.addEventListener('change', () => {
  chrome.storage.local.set({ captureEnabled: captureToggle.checked });
  showCapture(captureToggle.checked);
});

// ── App status ─────────────────────────────────────────────────────────────
// The host answers ping itself and reports whether the app's IPC server
// answered it. Any failure to get that far reads as "not running".

let opening = false;

function showStatus(running) {
  statusDot.className = 'dot ' + (running ? 'on' : 'off');
  statusText.textContent = running ? 'Connected to Convoy'
    : opening ? 'Opening Convoy…' : 'Convoy isn’t running';
  openBtn.hidden = running;
  openBtn.disabled = opening;
  if (running) opening = false;
}

function checkStatus() {
  chrome.runtime.sendNativeMessage(NATIVE_HOST, { type: 'ping' }, (response) => {
    showStatus(!chrome.runtime.lastError && response?.appRunning === true);
  });
}

// Routed through the background worker: it outlives this popup, and its
// launch path also replays a download that failed because the app was closed.
openBtn.addEventListener('click', () => {
  opening = true;
  showStatus(false);
  // A failed launch reports itself as a notification; just re-enable the button.
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

document.getElementById('settingsBtn').addEventListener('click', () => {
  chrome.tabs.create({ url: `chrome://extensions/?id=${chrome.runtime.id}` });
  window.close();
});
