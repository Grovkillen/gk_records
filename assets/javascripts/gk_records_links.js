// gk_records: the page of links, Lägg till koppling. #gk-records-add (the tab's link) opens the add box (GK GUI Stuff's
// choices box, a fieldset folded as core's: toggleFieldset on its legend), and the sorts offered follow the chosen kind:
// a kind's option names the sorts it may go to (data-targets, none when any sort will do; a single kind is a hidden
// field that carries them itself); the server searches only among allowed sorts anyway. Plain DOM, no jQuery.
(function () {
  'use strict';
  function show() {
    if (window.location.hash !== '#gk-records-add') return;
    var f = document.querySelector('#gk-records-add fieldset.collapsed');
    var lg = f && f.querySelector(':scope > legend'); // gk-r17 P2r: the legend of the add box records draws itself (GK GUI Stuff's choices box), not core markup
    if (lg && window.toggleFieldset) window.toggleFieldset(lg);
  }
  function sorts() {
    var kind = document.getElementById('gk_records_add_kind');
    var type = document.getElementById('gk_records_add_type');
    if (!kind || !type) return;
    var chosen = kind.options ? kind.options[kind.selectedIndex] : kind;
    var only = chosen && chosen.getAttribute('data-targets');
    var allowed = only ? only.split(' ') : null;
    var first = null;
    Array.prototype.forEach.call(type.options, function (o) {
      var ok = !allowed || allowed.indexOf(o.value) !== -1;
      o.disabled = !ok;
      o.hidden = !ok;
      if (ok && !first) first = o;
    });
    var sel = type.options[type.selectedIndex];
    if ((!sel || sel.disabled) && first) first.selected = true;
  }
  function ready() {
    show();
    sorts();
    var kind = document.getElementById('gk_records_add_kind');
    if (kind) kind.addEventListener('change', sorts);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready); else ready();
})();
