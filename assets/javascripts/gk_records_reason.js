// gk_records: the reason drawn by records' shell (gk_records_reason_field) and on the settings pages (SettingsHooks),
// both GK GUI Stuff's reason (gk_gui_stuff_reason_block) in records' mark .gk-records-reason-wrap[data-gk-records-reason]:
//   data-gk-records-reason-need "1": required; -min: the place's least length. The text area has the caller's id and
//   attributes from the server.
// What it does:
//   the caller's own label for the field beside it (label[for=<id>] and the line break after it) is hidden: the block's
//   heading is the label
//   the reason stands on its own line under the form's Save (in a table's cell, after it), never between Save and
//   Cancel; the Save is the one the caller marks (data-gk-reason-save), else the last submit button after the reason
//   in its own element, else the button or the paragraph of buttons right after its element (the caller's markup)
//   a # in the reason opens core's search for issues (core's data-auto-complete)
//   a form sent with a required reason left empty, or shorter than the least length, is not sent: the block's error
//   shows and the cursor goes to the reason; a reason hidden with its part of the form is left to the server, which
//   decides in any case (GkRecords::Reasons.check)
//   a field another plugin marks data-gk-reason gets the browser's "Please fill in" in the page's language
// The words come as data (script#gk-records-reason-texts, ReasonHooks). Reasons added later (a form fetched into a
// popup) are prepared when they appear. Plain DOM, no jQuery.
(function () {
  'use strict';
  if (window.GkRecordsReason) return;
  window.GkRecordsReason = true;
  var WRAP = '.gk-records-reason-wrap[data-gk-records-reason]';
  var SUBMIT = 'input[type=submit], button[type=submit], button:not([type])';
  var texts = null;
  function t(k) {
    if (!texts) {
      var d = document.getElementById('gk-records-reason-texts');
      try { texts = d ? JSON.parse(d.textContent || '{}') : {}; } catch (e) { texts = {}; }
    }
    return texts[k] || '';
  }
  function area(w) { return w.querySelector('.gk-gui-stuff-reason textarea'); }
  function after(a, b) { return !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING); }

  // the Save of the reason's form on the same row
  function saveButton(w, f) {
    var form = f && f.form;
    if (!form) return null;
    var marked = [].filter.call(form.querySelectorAll('[data-gk-reason-save]'), function (b) { return b.form === form; })[0];
    if (marked) return marked;
    var mine = function (b) { return b.form === form && !w.contains(b); };
    var row = w.parentElement;
    var own = row ? [].filter.call(row.querySelectorAll(SUBMIT), function (b) { return mine(b) && after(w, b); }) : [];
    if (own.length) return own[own.length - 1];
    for (var el = row; el && el !== form && form.contains(el); el = el.parentElement) {
      var next = el.nextElementSibling;
      if (!next) continue;
      if (next.matches(SUBMIT)) return mine(next) ? next : null;
      if (next.tagName !== 'P') return null;
      var bs = [].filter.call(next.querySelectorAll(SUBMIT), mine);
      return bs.length ? bs[bs.length - 1] : null;
    }
    return null;
  }
  // after the Save: in a table's cell beside it; in a form on a line of its own under the Save's line
  function place(w, f) {
    var b = saveButton(w, f);
    if (!b || !after(w, b)) return;
    if (b.closest('td')) {
      b.parentNode.insertBefore(w, b.nextSibling);
      return;
    }
    var line = b.parentNode, form = b.form;
    while (line && line !== form && line.parentNode !== form && window.getComputedStyle(line).display.indexOf('inline') === 0) line = line.parentNode;
    if (!line || line === form) line = b;
    var under = document.createElement('div');
    under.className = 'gk-records-reason-under';
    under.appendChild(w);
    line.parentNode.insertBefore(under, line.nextSibling);
  }
  // the caller's own label for the field (label[for=<the text area's id>]) beside the reason, outside the block, is
  // hidden with the line break right after it: the block's heading is the label, and the reason may move under Save.
  // A paragraph left with nothing visible goes too.
  function callerLabel(w, f) {
    var row = w.parentElement;
    if (!row || !f.id) return;
    [].forEach.call(row.querySelectorAll('label[for="' + f.id.replace(/(["\\])/g, '\\$1') + '"]'), function (lb) {
      if (w.contains(lb) || lb.parentElement !== row) return;
      lb.hidden = true;
      var next = lb.nextSibling;
      while (next && next.nodeType === 3 && !next.textContent.trim()) next = next.nextSibling;
      if (next && next.nodeType === 1 && next.tagName === 'BR') next.hidden = true;
    });
    return row;
  }
  // a paragraph the reason left with nothing visible in it (only the hidden label and space)
  function emptied(row) {
    if (!row || row.tagName !== 'P') return;
    var shown = [].some.call(row.childNodes, function (n) {
      return n.nodeType === 3 ? !!n.textContent.trim() : n.nodeType === 1 && !n.hidden; // gk-r17 P4r: only whether the caller's own paragraph still shows anything after its reason moved out; the text is never compared or used to find anything in core
    });
    if (!shown) row.hidden = true;
  }
  function prepare(root) {
    if (!root || !root.querySelectorAll) return;
    var list = [].slice.call(root.querySelectorAll(WRAP));
    if (root.matches && root.matches(WRAP)) list.push(root);
    list.forEach(function (w) {
      if (w.hasAttribute('data-gk-records-reason-ready')) return;
      w.setAttribute('data-gk-records-reason-ready', '1');
      var f = area(w);
      if (!f) return;
      f.setAttribute('data-auto-complete', 'true');
      var row = callerLabel(w, f);
      place(w, f);
      if (row && !row.contains(w)) emptied(row);
    });
  }

  // a required reason that is not written, or too short
  function lacking(w) {
    var f = area(w);
    if (!f || w.getAttribute('data-gk-records-reason-need') !== '1' || !w.getClientRects().length) return false;
    var min = parseInt(w.getAttribute('data-gk-records-reason-min'), 10) || 1;
    return f.value.trim().length < min;
  }
  function tell(w) {
    var f = area(w), err = w.querySelector('.gk-gui-stuff-reason-error');
    var min = parseInt(w.getAttribute('data-gk-records-reason-min'), 10) || 0;
    if (err) {
      // the block's own words (write a reason) are kept the first time, so that an emptied field says them again
      if (!err.hasAttribute('data-gk-records-reason-write')) err.setAttribute('data-gk-records-reason-write', err.textContent);
      err.textContent = min > 1 && f.value.trim() ? t('short').replace('%{count}', String(min)) : err.getAttribute('data-gk-records-reason-write');
      err.hidden = false;
    }
    f.setAttribute('aria-invalid', 'true');
  }
  // core marks a form sent (data-submitted) and refuses the next send, also when this one was stopped here: the mark
  // goes after core's handler, so that Save works once the reason is written
  document.addEventListener('submit', function (e) {
    var form = e.target;
    if (!form || !form.querySelectorAll) return;
    var missing = [].filter.call(form.querySelectorAll(WRAP), lacking);
    if (!missing.length) return;
    e.preventDefault();
    missing.forEach(tell);
    area(missing[0]).focus();
    setTimeout(function () { form.removeAttribute('data-submitted'); }, 0);
  }, true);

  // the browser's own "Please fill in this field" is in the browser's language: a field marked data-gk-reason says it
  // in the page's, and is plain again once something is written
  document.addEventListener('invalid', function (e) {
    var f = e.target;
    if (!f.matches || !f.matches('[data-gk-reason]')) return;
    if (f.validity.valueMissing) f.setCustomValidity(t('missing'));
    else if (f.validity.tooShort) f.setCustomValidity(t('short').replace('%{count}', String(f.minLength)));
  }, true);
  document.addEventListener('input', function (e) {
    var f = e.target;
    if (f.matches && f.matches('[data-gk-reason]')) f.setCustomValidity('');
  }, true);

  function start() {
    prepare(document);
    if (window.MutationObserver) {
      new MutationObserver(function (ms) {
        ms.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType === 1) prepare(n); }); });
      }).observe(document.body, { childList: true, subtree: true });
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
