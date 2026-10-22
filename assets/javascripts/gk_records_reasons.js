// gk_records, Administration > Skäl: a row's Save is dimmed and off until the row's mode is changed, and on again when
// it is; the reason alone changes nothing to save. Without this file every Save is on, as before. Plain DOM, no jQuery.
(function () {
  function init() {
    document.querySelectorAll('table.gk-records-reasons form.gk-records-reason-mode-form').forEach(function (form) {
      var sel = form.querySelector('select[name="mode"]'), btn = form.querySelector('input[type=submit]');
      if (!sel || !btn || form.dataset.gkReady) return;
      form.dataset.gkReady = '1';
      var start = sel.value, hint = form.dataset.unchanged || '', title = btn.title;
      function sync() {
        var same = sel.value === start;
        btn.disabled = same;
        btn.title = same ? hint : title;
      }
      sel.addEventListener('change', sync);
      sync();
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init); else init();
})();
