(function() {
  function scanPageMedia() {
    const urls = new Set();
    
    document.querySelectorAll('video[src], audio[src], video source[src], audio source[src]').forEach(el => {
      const url = el.src || el.currentSrc;
      if (url) urls.add(url);
    });
    
    document.querySelectorAll('img[src], img[data-src], img[data-original], img[data-lazy]').forEach(el => {
      const url = el.src || el.dataset.src || el.dataset.original || el.dataset.lazy;
      if (url) urls.add(url);
    });
    
    document.querySelectorAll('source[src], embed[src], object[data], iframe[src]').forEach(el => {
      const url = el.src || el.data;
      if (url) urls.add(url);
    });
    
    const links = document.querySelectorAll('a[href]');
    links.forEach(a => {
      const href = a.href;
      const ext = href.split('.').pop()?.toLowerCase().split('?')[0];
      const mediaExts = ['mp4', 'webm', 'ogg', 'mov', 'avi', 'mkv', 'flv', 'm4v', 'mp3', 'wav', 'flac', 'aac', 'm4a', 'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'svg', 'zip', 'rar', '7z', 'tar', 'gz', 'pdf', 'dmg', 'pkg', 'iso'];
      if (ext && mediaExts.includes(ext)) {
        urls.add(href);
      }
    });
    
    return Array.from(urls);
  }
  
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message.type === 'getPageMedia') {
      sendResponse({ urls: scanPageMedia() });
      return true;
    }
  });
})();
