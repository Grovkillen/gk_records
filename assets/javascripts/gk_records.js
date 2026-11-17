// gk_records: the reply and correct of the writing box (GK GUI Stuff's, found by records' own classes on its parts;
// Svara and Rätta are icon buttons on each note) in the records list, records' banner (an error on a page of its
// own, as GK GUI Stuff's banner), and a filter's Apply link. Makulera is GK GUI Stuff's button with a reason, drawn by the server. GK GUI Stuff is
// required and always loaded. Plain DOM, no jQuery.
(function () {
  'use strict';
  function init(root) {
    if (root.dataset.ready) return;
    root.dataset.ready = '1';
    var form = root.querySelector('.gk-records-form');
    if (!form) return;
    var ctx = form.querySelector('.gk-records-context'), reset = form.querySelector('.gk-records-reset');
    function set(mode, id, kind) {
      form.querySelector('.gk-records-parent').value = mode === 'reply' ? id : '';
      form.querySelector('.gk-records-corrects').value = mode === 'correct' ? id : '';
      // A kind the writing box does not offer (records.more_note_kinds off) leaves the choice as it is
      var sel = form.querySelector('.gk-records-kind');
      // (and a single kind is no list: GK GUI Stuff's writing box draws it as text with a hidden field)
      if (kind && sel.options && Array.prototype.some.call(sel.options, function (o) { return o.value === kind; })) sel.value = kind;
      ctx.textContent = '';
      if (mode) {
        // core's icon through GK GUI Stuff (icons first, then core's sprite), then the note's number
        ctx.appendChild(window.GkGui.icon(mode === 'reply' ? 'reply' : 'edit', mode === 'reply' ? '↳' : '✎', 14));
        ctx.appendChild(document.createTextNode(' #' + id));
      }
      reset.hidden = !mode;
      form.querySelector('.gk-records-body').focus();
    }
    root.addEventListener('click', function (e) {
      var t = e.target.closest('a, button');
      if (!t) return;
      if (t.classList.contains('gk-records-reply')) { e.preventDefault(); set('reply', t.dataset.id, 'answer'); }
      else if (t.classList.contains('gk-records-correct')) { e.preventDefault(); set('correct', t.dataset.id); }
      else if (t.classList.contains('gk-records-reset')) { e.preventDefault(); set('', '', 'comment'); }
    });
  }
  // records' mark for a banner (data-gk-records-banner="<level>", its text the message): GK GUI Stuff's banner at the
  // top of the content in place of the mark
  function banners() {
    document.querySelectorAll('[data-gk-records-banner]').forEach(function (m) {
      var b = window.GkGui.banner.show({ key: 'records.' + (m.id || 'page'), level: m.getAttribute('data-gk-records-banner'),
                                         text: m.textContent.trim(), where: false });
      if (b) m.remove();
    });
  }
  function all() {
    document.querySelectorAll('[data-gk-records-list]').forEach(init);
    banners();
  }
  // a filter's Apply (data-gk-records-submit), drawn as core's link above its lists, sends the form round it
  document.addEventListener('click', function (e) {
    var a = e.target.closest ? e.target.closest('a[data-gk-records-submit]') : null;
    var form = a ? a.closest('form') : null;
    if (!form) return;
    e.preventDefault();
    form.requestSubmit();
  });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', all); else all();
})();
