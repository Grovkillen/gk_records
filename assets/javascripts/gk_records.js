// gk_records: tabs in the records list, and the note form's reply, correct and void. Plain DOM, no jQuery.
(function () {
  // Core's icon through gui_stuff (icons first, then core's sprite); the character only without it
  function ic(name, ch, size) { return window.GkGui && window.GkGui.icon ? window.GkGui.icon(name, ch, size || 14) : document.createTextNode(ch); }
  function init(root) {
    if (root.dataset.ready) return;
    root.dataset.ready = '1';
    root.querySelectorAll('.gk-records-tabs a[data-tab]').forEach(function (a) {
      a.addEventListener('click', function (e) {
        e.preventDefault();
        root.querySelectorAll('.gk-records-tabs a').forEach(function (x) { x.classList.toggle('selected', x === a); });
        root.querySelectorAll('.gk-records-pane').forEach(function (p) { p.hidden = p.dataset.pane !== a.dataset.tab; });
      });
    });
    var form = root.querySelector('.gk-records-form');
    if (!form) return;
    var ctx = form.querySelector('.gk-records-context'), reset = form.querySelector('.gk-records-reset');
    function set(mode, id, kind) {
      form.querySelector('.gk-records-parent').value = mode === 'reply' ? id : '';
      form.querySelector('.gk-records-corrects').value = mode === 'correct' ? id : '';
      // A kind the writing box does not offer (records.more_note_kinds off) leaves the choice as it is
      var sel = form.querySelector('.gk-records-kind');
      if (kind && Array.prototype.some.call(sel.options, function (o) { return o.value === kind; })) sel.value = kind;
      ctx.textContent = '';
      if (mode) { ctx.appendChild(ic(mode === 'reply' ? 'reply' : 'edit', form.dataset[mode + 'Label'] || '', 14)); ctx.appendChild(document.createTextNode(' #' + id)); }
      reset.hidden = !mode;
      form.querySelector('.gk-records-body').focus();
    }
    form.dataset.replyLabel = root.dataset.replyLabel || '\u21b3';
    form.dataset.correctLabel = root.dataset.correctLabel || '\u270e';
    root.addEventListener('click', function (e) {
      var t = e.target.closest('a');
      if (!t) return;
      if (t.classList.contains('gk-records-reply')) { e.preventDefault(); set('reply', t.dataset.id, 'answer'); }
      else if (t.classList.contains('gk-records-correct')) { e.preventDefault(); set('correct', t.dataset.id); }
      else if (t.classList.contains('gk-records-reset')) { e.preventDefault(); set('', '', 'comment'); }
      else if (t.classList.contains('gk-records-void')) {
        e.preventDefault();
        // Administration > Skäl decides; off asks nothing, optional takes an empty answer
        var mode = t.dataset.reasonMode || 'required';
        var reason = '';
        if (mode !== 'off') {
          reason = window.prompt(t.dataset.prompt);
          if (reason === null) return;
          if (mode === 'required' && !reason.trim()) return;
        }
        var f = document.createElement('form');
        f.method = 'post'; f.action = t.dataset.url;
        [['reason', reason], ['authenticity_token', (document.querySelector('meta[name=csrf-token]') || {}).content || '']].forEach(function (p) {
          var i = document.createElement('input'); i.type = 'hidden'; i.name = p[0]; i.value = p[1]; f.appendChild(i);
        });
        document.body.appendChild(f); f.submit();
      }
    });
  }
  function all() { document.querySelectorAll('[data-gk-records-list]').forEach(init); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', all); else all();
})();
