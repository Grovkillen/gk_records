// gk_records: the row Verifieringsstatus. The pill that is a button (data-gk-records-verification-pill)
// opens the box under it with GK GUI Stuff's popover (GkGui.popover.open, in its wide width); the box is a fresh copy of the hidden panel drawn by
// _verification.html.erb, so Avbryt and Esc leave nothing behind. In the box:
//   a step (a pill that is a button) is chosen with a click, Enter or Space; the chosen one is filled (aria-pressed)
//   Spara is grey until a step other than the current one is chosen, and the reason is written when it is required
//   with reasons off a click on another step saves at once
//   the arrow keys move between the steps (right and left follow the writing direction, up and down too), Ctrl or
//   Meta and Enter saves, Esc closes (the popover)
// Saving: the box closes, the rail says Sparar…, the change is posted as JSON; the answer's row takes the
// row's place and says Sparat; a failure says Inte sparat with the reason, the pill stays, and the box opens again with
// the step chosen and the reason kept. A step moved while a review is open asks first (code open_review) in GK GUI
// Stuff's popover at the pill, in the role warning, with the server's question, the change's button and Avbryt; on
// the button it sends withdraw=1, on Avbryt the box opens again as it was. GK GUI Stuff is required and always
// loaded. Plain DOM, no jQuery.
(function () {
  'use strict';
  var G = window.GkGui;
  function token() { var m = document.querySelector('meta[name="csrf-token"]'); return m ? m.getAttribute('content') : ''; }
  function words(rail) {
    try { return JSON.parse(rail.getAttribute('data-gk-records-verification-words') || '{}'); } catch (e) { return {}; }
  }
  function setRail(rail, state, word) { G.save.set(rail, state, word); }

  function steps(box) { return [].slice.call(box.querySelectorAll('[data-gk-records-verification-step]')); }
  function chosen(box) { return box.querySelector('[data-gk-records-verification-step][aria-pressed="true"]'); }
  // GK GUI Stuff's reason in the box (gk_gui_stuff_reason_block): its text area, required by aria-required, with the
  // place's least length on the text area itself (data-gk-records-reason-min)
  function reasonField(box) { return box.querySelector('form[data-gk-records-verification-form] .gk-gui-stuff-reason textarea[name="reason"]'); }
  function reasonNeeded(r) { return !!r && r.getAttribute('aria-required') === 'true'; }
  function reasonMin(r) { return (r && parseInt(r.getAttribute('data-gk-records-reason-min'), 10)) || 1; }

  // Spara: a step chosen, not the current one, and the reason written when it is required
  function canSave(rail, box) {
    var c = chosen(box), r = reasonField(box), now = rail.getAttribute('data-gk-records-verification-status');
    var ok = !!c && c.getAttribute('data-gk-records-verification-step') !== now;
    if (ok && reasonNeeded(r)) ok = r.value.trim().length >= reasonMin(r);
    var save = box.querySelector('[data-gk-records-verification-save]');
    if (save) save.disabled = !ok;
    return ok;
  }

  // quiet: the step is only marked (the box opened again after a failed save), never saved at once, or a save that
  // fails with reasons off would be sent again and again
  function choose(rail, box, step, quiet) {
    steps(box).forEach(function (s) {
      var on = s === step;
      s.setAttribute('aria-pressed', on ? 'true' : 'false');
      s.classList.toggle('gk-gui-stuff-pill-chosen', on);
    });
    var mode = rail.getAttribute('data-gk-records-verification-reason');
    // with reasons off a click on another step saves at once and closes the box
    if (!quiet && mode === 'off' && canSave(rail, box)) { save(rail, step.getAttribute('data-gk-records-verification-step'), '', false); return; }
    canSave(rail, box);
  }

  function open(rail, keep) {
    var pill = rail.querySelector('[data-gk-records-verification-pill]');
    var panel = rail.querySelector('[data-gk-records-verification-panel]');
    if (!pill || !panel) return null;
    var content = document.createElement('div');
    [].forEach.call(panel.children, function (c) { content.appendChild(c.cloneNode(true)); });
    renameIds(content);
    pill.setAttribute('aria-expanded', 'true');
    var d = G.popover.open(pill, content, { className: 'gk-records-verification-popover', width: 'wide', onClose: function () { pill.setAttribute('aria-expanded', 'false'); } });
    var box = d && d.querySelector('.gk-gui-stuff-popover-box');
    if (!box) return null;
    // every step unpressed when the box opens; after a failed save the step and the reason come back
    steps(box).forEach(function (s) { s.setAttribute('aria-pressed', 'false'); s.classList.remove('gk-gui-stuff-pill-chosen'); });
    if (keep) {
      var again = box.querySelector('[data-gk-records-verification-step="' + keep.status + '"]');
      if (again) choose(rail, box, again, true);
      var r = reasonField(box);
      if (r) r.value = keep.reason || '';
    }
    canSave(rail, box);
    var first = chosen(box) || box.querySelector('[data-gk-records-verification-step]:not([disabled])');
    if (first) setTimeout(function () { first.focus({ preventScroll: true }); }, 0);
    box._gkRecordsRail = rail;
    return box;
  }

  // the copy in the box has ids of its own (the reason's label, hint and text area), so no id stands twice on the page
  function renameIds(c) {
    c.querySelectorAll('[id]').forEach(function (n) { n.id = n.id + '-open'; });
    ['for', 'aria-describedby', 'aria-labelledby'].forEach(function (a) {
      c.querySelectorAll('[' + a + ']').forEach(function (n) {
        n.setAttribute(a, n.getAttribute(a).split(/\s+/).map(function (x) { return x ? x + '-open' : x; }).join(' '));
      });
    });
  }

  function closeOf(box) {
    var d = box && box.closest('details.gk-gui-stuff-popover');
    if (d) G.popover.close(d);
  }

  // A step moved while a review is open: the server's question in GK GUI Stuff's popover at the pill, in the role
  // warning; the change's button sends again with withdraw=1, Avbryt (or Esc, or a click outside) opens the box again
  // with the step and the reason kept
  function askWithdraw(rail, message, keep) {
    var pill = rail.querySelector('[data-gk-records-verification-pill]');
    if (!pill) return;
    var w = words(rail), yes = false;
    var content = document.createElement('div');
    var p = document.createElement('p'); p.textContent = message || '';
    var row = document.createElement('div'); row.className = 'gk-gui-stuff-popover-buttons';
    var go = document.createElement('button'); go.type = 'button'; go.textContent = w.withdraw || '';
    var cancel = document.createElement('button'); cancel.type = 'button'; cancel.textContent = w.cancel || '';
    cancel.setAttribute('data-gk-gui-popover-cancel', '1');
    row.appendChild(go); row.appendChild(cancel);
    content.appendChild(p); content.appendChild(row);
    var d = G.popover.open(pill, content, {
      role: 'warning', className: 'gk-records-verification-confirm',
      onClose: function () {
        if (yes) { save(rail, keep.status, keep.reason, true); return; }
        setRail(rail, 'direct', null);
        open(rail, keep);
      }
    });
    go.addEventListener('click', function () { yes = true; G.popover.close(d); });
    setTimeout(function () { go.focus({ preventScroll: true }); }, 0);
  }

  function save(rail, status, reason, withdraw) {
    var w = words(rail);
    var box = document.querySelector('.gk-records-verification-popover .gk-gui-stuff-popover-box');
    if (box && box._gkRecordsRail === rail) closeOf(box);
    setRail(rail, 'changed', w.saving);
    var fd = new URLSearchParams();
    fd.append('target', rail.getAttribute('data-gk-records-verification'));
    fd.append('back_url', rail.getAttribute('data-gk-records-verification-back') || '');
    fd.append('status', status);
    fd.append('reason', reason || '');
    if (withdraw) fd.append('withdraw', '1');
    var keep = { status: status, reason: reason };
    var failed = function (why) {
      setRail(rail, 'failed', (w.not_saved || '%{why}').replace('%{why}', why || w.no_answer || ''));
      open(rail, keep);
    };
    fetch(rail.getAttribute('data-gk-gui-save-url'), {
      method: 'POST', credentials: 'same-origin', body: fd,
      headers: { 'X-CSRF-Token': token(), Accept: 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
    }).then(function (res) {
      return res.json().then(function (j) { return j; }, function () { return null; });
    }).then(function (j) {
      if (!j) { failed(null); return; }
      if (j.ok && j.html) {
        var t = document.createElement('template');
        t.innerHTML = j.html.trim();
        var fresh = t.content.querySelector('.gk-records-verification-box');
        if (!fresh) { window.location.reload(); return; }
        rail.replaceWith(fresh);
        setRail(fresh, 'saved', w.saved);
        return;
      }
      if (j.code === 'open_review') {
        // the open review is taken back only on the change's button; Avbryt: nothing is changed and the box opens
        // again as it was
        askWithdraw(rail, j.message, keep);
        return;
      }
      failed(j.message);
    }).catch(function () { failed(null); });
  }

  document.addEventListener('click', function (e) {
    var t = e.target;
    if (!t.closest) return;
    var pill = t.closest('[data-gk-records-verification-pill]');
    if (pill) {
      var rail = pill.closest('.gk-records-verification-box');
      if (rail) { e.preventDefault(); open(rail, null); }
      return;
    }
    var step = t.closest('.gk-records-verification-popover [data-gk-records-verification-step]');
    if (step && !step.disabled) {
      var box = step.closest('.gk-gui-stuff-popover-box');
      if (box && box._gkRecordsRail) { e.preventDefault(); choose(box._gkRecordsRail, box, step); }
    }
  });

  // Spara: the form in the box never posts itself; the script sends the chosen step and the reason
  document.addEventListener('submit', function (e) {
    var f = e.target;
    var box = f.closest && f.closest('.gk-records-verification-popover .gk-gui-stuff-popover-box');
    // only the box's own form (its data mark): the review's forms inside the box (GK Signoff) post as they always did
    if (!box || !box._gkRecordsRail || !f.hasAttribute('data-gk-records-verification-form')) return;
    e.preventDefault();
    var rail = box._gkRecordsRail, c = chosen(box);
    if (!c || !canSave(rail, box)) return;
    var r = reasonField(box);
    save(rail, c.getAttribute('data-gk-records-verification-step'), r ? r.value.trim() : '', false);
  });

  document.addEventListener('input', function (e) {
    var box = e.target.closest && e.target.closest('.gk-records-verification-popover .gk-gui-stuff-popover-box');
    if (box && box._gkRecordsRail) canSave(box._gkRecordsRail, box);
  });

  // keys in the box: the arrows between the steps that may be chosen (round), Ctrl or Meta and Enter saves
  document.addEventListener('keydown', function (e) {
    var box = e.target.closest && e.target.closest('.gk-records-verification-popover .gk-gui-stuff-popover-box');
    if (!box || !box._gkRecordsRail) return;
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      var f = box.querySelector('form[data-gk-records-verification-form]');
      if (f && canSave(box._gkRecordsRail, box)) f.requestSubmit ? f.requestSubmit() : f.dispatchEvent(new Event('submit', { cancelable: true, bubbles: true }));
      return;
    }
    var step = e.target.closest('[data-gk-records-verification-step]');
    if (!step || ['ArrowRight', 'ArrowLeft', 'ArrowUp', 'ArrowDown'].indexOf(e.key) < 0) return;
    var all = steps(box).filter(function (s) { return !s.disabled && s.getClientRects().length > 0; });
    var i = all.indexOf(step);
    if (i < 0) return;
    var rtl = window.getComputedStyle(box).direction === 'rtl';
    var forward = e.key === 'ArrowDown' || e.key === (rtl ? 'ArrowLeft' : 'ArrowRight');
    e.preventDefault();
    all[(i + (forward ? 1 : -1) + all.length) % all.length].focus();
  });
})();
