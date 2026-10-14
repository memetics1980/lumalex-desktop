/// Installed in every WebKit frame at document start, independently of
/// publisher scripts and their load timing. Both readers use the same native
/// navigation callback for lookup and the shared Flutter Copy/Lookup menu.
String macosReaderInteractionJavascript() => r'''
(() => {
  if (window.__lumalexMacReaderInteractions) return;
  window.__lumalexMacReaderInteractions = true;
  const ignored = 'a,button,input,select,textarea,[role="button"],[contenteditable="true"],.sound,.speaker,.senseButton,.cdepe-nav,.maldpe-nav';
  document.addEventListener('contextmenu', event => {
    event.preventDefault();
    event.stopImmediatePropagation();
    const text = String(window.getSelection() || '').trim();
    if (!text) return;
    let x = event.clientX, y = event.clientY;
    let frame = window;
    while (frame !== window.top && frame.frameElement) {
      const bounds = frame.frameElement.getBoundingClientRect();
      x += bounds.left; y += bounds.top;
      frame = frame.parent;
    }
    const bridge = window.top.flutter_inappwebview;
    if (bridge && typeof bridge.callHandler === 'function') {
      bridge.callHandler('dictionaryWindowsSelectionMenuRequested', text, window.location.href, x, y);
    }
  }, true);
  document.addEventListener('dblclick', event => {
    const raw = event.target;
    const target = raw && typeof raw.closest === 'function' ? raw : raw && raw.parentElement;
    if (!target || target.closest(ignored)) return;
    event.stopImmediatePropagation();
    setTimeout(() => {
      const selected = String(window.getSelection() || '').trim();
      const match = selected.match(/[\p{L}\p{M}\p{N}]+(?:[’'\-][\p{L}\p{M}\p{N}]+)*/u);
      if (!match) return;
      const url = new URL('/__lumalex_selection_lookup__', window.top.location.href);
      url.searchParams.set('text', match[0]);
      const owner = window.frameElement;
      if (owner && owner.dataset.token) url.searchParams.set('token', owner.dataset.token);
      window.top.location.assign(url.href);
    }, 0);
  }, true);
})();
''';
