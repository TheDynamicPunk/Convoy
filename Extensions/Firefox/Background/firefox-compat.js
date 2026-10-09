// Firefox adapter. Loaded ahead of background.js by Extensions/Firefox/manifest.json
// and by no other build. background.js stays the one implementation; this file
// supplies the two things it calls that Firefox's `chrome` namespace lacks.
(function () {
  'use strict';

  // 1. downloads.onDeterminingFilename does not exist in Firefox. background.js
  // uses it as the hold point for cancelling a download before the browser's
  // Save As dialog (see interceptDownload). Firefox has onCreated, which fires
  // once the download exists, after any "always ask where to save" prompt.
  // The adapter re-fires onCreated through the signature background.js expects.
  // suggest() does nothing: a download left to the browser needs no answer.
  if (chrome.downloads && !chrome.downloads.onDeterminingFilename) {
    const listeners = new Set();
    chrome.downloads.onDeterminingFilename = {
      addListener: (fn) => { listeners.add(fn); },
      removeListener: (fn) => { listeners.delete(fn); },
      hasListener: (fn) => listeners.has(fn),
    };
    chrome.downloads.onCreated.addListener((item) => {
      for (const fn of listeners) {
        try {
          fn(item, () => {});
        } catch (e) {
          console.error('[MDL] download listener failed:', e);
        }
      }
    });
  }

  // 2. Notifications accept only type, title, message and iconUrl, and throw on
  // anything else. The "app didn't open" prompt asks for a button and for the
  // notification to stay up; here the whole notification is the control
  // (background.js already opens the app on onClicked), so say that in the text.
  if (chrome.notifications) {
    const create = chrome.notifications.create.bind(chrome.notifications);
    chrome.notifications.create = function (...args) {
      const at = typeof args[0] === 'string' ? 1 : 0;
      const options = { ...args[at] };
      const hadButtons = Array.isArray(options.buttons) && options.buttons.length > 0;
      delete options.buttons;
      delete options.requireInteraction;
      if (hadButtons && options.message) options.message += ' Click to try again.';
      args[at] = options;
      return create(...args);
    };
    if (!chrome.notifications.onButtonClicked) {
      chrome.notifications.onButtonClicked = {
        addListener: () => {},
        removeListener: () => {},
        hasListener: () => false,
      };
    }
  }
})();
