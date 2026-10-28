// export_log: when the browser starts printing this page (Ctrl+P or the menu), the page tells the server once, so that
// the print is in the log ("utskrift begärd": the browser never says whether paper came out).
// No jQuery.
(function () {
  'use strict';
  var sent = false;
  function tell() {
    if (sent) return;
    sent = true;
    var el = document.getElementById('gk-records-export-print');
    if (!el) return;
    var token = (document.querySelector('meta[name="csrf-token"]') || {}).content || '';
    var body = new FormData();
    body.append('authenticity_token', token);
    body.append('path', window.location.pathname + window.location.search);
    try {
      if (!(navigator.sendBeacon && navigator.sendBeacon(el.getAttribute('data-url'), body))) {
        fetch(el.getAttribute('data-url'), { method: 'POST', body: body, credentials: 'same-origin', keepalive: true });
      }
    } catch (e) { /* a print is never stopped by the log */ }
  }
  window.addEventListener('beforeprint', tell);
  if (window.matchMedia) {
    var mq = window.matchMedia('print');
    if (mq.addEventListener) mq.addEventListener('change', function (e) { if (e.matches) tell(); });
  }
})();
