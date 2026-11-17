// gk_records: the issue's history. The entry's note beside the row Verifieringsstatus is the reason: it gets the
// classes of GK GUI Stuff's shown reason (its edge and soft ground; core's own indent of the note stays) with Skäl on
// the line at its top; records' own class on it only says that it is done. The note stays a note, so Anteckningar has
// it. The row is found by
// records' own mark on it (.gk-records-journal-verification, drawn by Verification::HistoryLine), the note by core's
// own id for it (journal-<id>-notes), never by its place in the entry. Plain DOM, no jQuery.
(function () {
  'use strict';
  if (window.GkRecordsJournal) return;
  window.GkRecordsJournal = true;
  function mark() {
    document.querySelectorAll('.journal .gk-records-journal-verification').forEach(function (s) {
      var j = s.closest('.journal'), w = j && j.querySelector('[id^="journal-"][id$="-notes"]');
      if (!w || w.classList.contains('gk-records-journal-reason') || !w.textContent.trim()) return;
      w.classList.add('gk-gui-stuff-reason-shown', 'gk-records-journal-reason');
      var b = document.createElement('span');
      b.className = 'gk-gui-stuff-reason-shown-by';
      b.textContent = s.getAttribute('data-reason-label');
      w.insertBefore(b, w.firstChild);
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mark); else mark();
  // the history's tabs fetch their content again
  if (window.MutationObserver) {
    var start = function () { new MutationObserver(mark).observe(document.body, { childList: true, subtree: true }); };
    if (document.body) start(); else document.addEventListener('DOMContentLoaded', start);
  }
})();
