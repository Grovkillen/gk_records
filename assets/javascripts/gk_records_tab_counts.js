// gk_records: with the setting tab_counts the issue's tabs Kopplingar and Bedömningar say their number, as GK GUI
// Stuff's count after the tab's word (GkGui.count, the same markup as gk_gui_stuff_count). Core writes a tab's label
// from a key, so the number is put after it on the page. The numbers come as data (script#gk-records-tab-counts, drawn
// by IssueHooks); the tab is found by core's own id for it (tab-<name>). Plain DOM, no jQuery.
(function () {
  'use strict';
  function put() {
    var data = document.getElementById('gk-records-tab-counts');
    if (!data) return;
    var counts;
    try { counts = JSON.parse(data.textContent || '{}'); } catch (e) { return; }
    Object.keys(counts).forEach(function (name) {
      var a = document.getElementById('tab-' + name);
      if (!a || a.hasAttribute('data-gk-records-count')) return;
      a.setAttribute('data-gk-records-count', '1');
      a.appendChild(document.createTextNode(' '));
      a.appendChild(window.GkGui.count({ n: counts[name] }));
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', put); else put();
})();
