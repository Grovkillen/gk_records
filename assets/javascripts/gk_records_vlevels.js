// gk_records: the levels of a verification place (_verification_levels.html.erb), GK GUI Stuff's choice list in the form
// where the place is set up and saved with that form's Save; nothing is saved here. Unticking an optional level that
// has records opens a box under the level's word (GkGui.popover.open, in its wide width) with how many, the levels they may go to (a view
// segment), the reason, and Flytta och slå av with Avbryt; for a level that is off but kept by its records also
// Behåll nivån. Flytta och slå av writes the level and the reason into the hidden fields [move][<step>] and
// [reason][<step>] and leaves the box unticked, with a quiet line that the move is made when the page is saved.
// Behåll nivån ticks the box again with the value 1 (the level is switched on with the page). Avbryt, Esc and a
// click outside tick the level again as it was drawn and empty the fields; so does ticking it again by hand. On the
// tracker's form the levels are shown while the check box Verifieringsstatus is ticked
// (data-gk-records-vlevels-follow names it). In the box's segment a level unticked on the page is disabled. The box's segment and reason have no name, so the form never posts them,
// and Enter in the reason never sends the form. Plain DOM, no jQuery.
(function () {
  'use strict';
  if (window.GkRecordsVlevels) return;

  function boxOf(n) { return n && n.closest ? n.closest('.gk-records-vlevels[data-gk-records-vlevels]') : null; }

  // the level's word as the box's anchor: the label of the row's choice (GK GUI Stuff's choice list draws it), found
  // from records' own mark on the pill in it
  function wordOf(li) {
    var w = li && li.querySelector('.gk-records-vlevel-word');
    return w ? w.closest('label') : null;
  }

  function hiddenField(li, kind, step) {
    return li.querySelector('input[type=hidden][data-gk-records-vlevels-field="' + kind + '-' + step + '"]');
  }

  // the quiet line after the level: what the page's Save will do with it, or nothing
  function planned(li, text) {
    var p = li.querySelector('[data-gk-records-vlevel-planned]');
    if (!p) return;
    p.textContent = text || '';
    p.hidden = !text;
  }

  function setFields(li, step, moveTo, reason) {
    var m = hiddenField(li, 'move', step), r = hiddenField(li, 'reason', step);
    if (m) m.value = moveTo || '';
    if (r) r.value = reason || '';
  }

  // the level as it was drawn: ticked, its own value (1, or kept for a level kept by its records), no move
  function restore(cb) {
    var li = cb.closest('.gk-records-vlevel');
    cb.checked = true;
    cb.value = cb.getAttribute('data-gk-records-vlevel-value') || '1';
    if (!li) return;
    setFields(li, cb.getAttribute('data-gk-records-vlevel-check'), null, null);
    planned(li, null);
  }

  // the hidden move box copied, its ids made its own so that the labels point into the open box
  function copyOf(panel) {
    var c = panel.cloneNode(true);
    c.hidden = false;
    c.removeAttribute('data-gk-records-vlevels-move');
    c.removeAttribute('class');
    c.querySelectorAll('[id]').forEach(function (n) { n.id = n.id + '-open'; });
    ['for', 'aria-describedby', 'aria-labelledby'].forEach(function (a) {
      c.querySelectorAll('[' + a + ']').forEach(function (n) {
        n.setAttribute(a, n.getAttribute(a).split(/\s+/).map(function (x) { return x ? x + '-open' : x; }).join(' '));
      });
    });
    return c;
  }

  function openMove(cb, step, panel) {
    var li = cb.closest('.gk-records-vlevel');
    var anchor = wordOf(li);
    if (!anchor) return;
    var m = { cb: cb, li: li, step: step, need: panel.getAttribute('data-gk-records-vlevels-need') === '1', done: false };
    var d = window.GkGui.popover.open(anchor, copyOf(panel), {
      className: 'gk-records-vlevels-popover', role: 'warning', width: 'wide',
      onClose: function () { if (!m.done) restore(cb); }
    });
    var fb = d && d.querySelector('.gk-gui-stuff-popover-box');
    if (!fb) return;
    fb._gkRecordsVlevels = m;
    offTargets(boxOf(cb), fb);
    var ta = fb.querySelector('.gk-gui-stuff-reason textarea');
    // a box opened again after a refused save keeps the reason that was written
    var kept = hiddenField(li, 'reason', step);
    if (ta && kept && kept.value && !ta.value) ta.value = kept.value;
    if (ta) setTimeout(function () { ta.focus({ preventScroll: true }); }, 0);
  }

  // the segment's levels that are unticked in this place on the page right now cannot be moved to (they go when the
  // page is saved): their buttons are disabled, and the choice goes to the first level that stays
  function offTargets(box, fb) {
    var seg = fb.querySelector('[data-gk-records-vlevels-target]');
    if (!box || !seg) return;
    var first = null, lost = false;
    seg.querySelectorAll('button[value]').forEach(function (b) {
      var c = box.querySelector('input[type=checkbox][data-gk-records-vlevel-check="' + b.value + '"]');
      b.disabled = !!(c && !c.checked);
      if (b.disabled && b.getAttribute('aria-pressed') === 'true') lost = true;
      if (!b.disabled && !first) first = b;
    });
    if (!lost || !first) return;
    window.GkGuiViewSegment.press(seg, first.value, false, true);
  }

  // the level's box when it is open, closed without ticking or unticking anything (its onClose does nothing)
  function closeOpen(li) {
    var anchor = wordOf(li);
    var d = anchor && anchor._gkGuiPopover;
    if (!d || !d.isConnected || !d.open) return;
    var fb = d.querySelector('.gk-gui-stuff-popover-box');
    if (fb && fb._gkRecordsVlevels) fb._gkRecordsVlevels.done = true;
    closeBox(fb || d);
  }

  function closeBox(fb) {
    var d = fb.closest('details.gk-gui-stuff-popover');
    if (d) window.GkGui.popover.close(d);
  }

  // Flytta och slå av: the level and the reason go into the hidden fields; the box stays unticked
  function go(fb) {
    var m = fb._gkRecordsVlevels;
    if (!m) return;
    var seg = fb.querySelector('[data-gk-records-vlevels-target]');
    var pressed = seg && seg.querySelector('button[aria-pressed="true"]');
    var ta = fb.querySelector('.gk-gui-stuff-reason textarea');
    var reason = ta ? ta.value.trim() : '';
    if (m.need && !reason) {
      var err = fb.querySelector('.gk-gui-stuff-reason-error');
      if (err) err.hidden = false;
      if (ta) { ta.setAttribute('aria-invalid', 'true'); ta.focus(); }
      return;
    }
    if (!pressed) return;
    m.done = true;
    m.cb.checked = false;
    setFields(m.li, m.step, pressed.value, reason);
    var line = m.li.querySelector('[data-gk-records-vlevel-planned]');
    var word = pressed.getAttribute('data-gk-gui-view-text') || pressed.textContent.trim();
    if (line) planned(m.li, (line.getAttribute('data-gk-records-vlevel-planned') || '').replace('%{step}', word));
    closeBox(fb);
  }

  // Behåll nivån: the kept level is ticked again to be switched on with the page; nothing is moved
  function keep(fb) {
    var m = fb._gkRecordsVlevels;
    if (!m) return;
    m.done = true;
    m.cb.checked = true;
    m.cb.value = '1';
    setFields(m.li, m.step, null, null);
    var line = m.li.querySelector('[data-gk-records-vlevel-planned]');
    planned(m.li, line ? line.getAttribute('data-gk-records-vlevel-keep-planned') : null);
    closeBox(fb);
  }

  document.addEventListener('change', function (e) {
    var t = e.target;
    if (!t || !t.matches) return;
    // the tracker's check box Verifieringsstatus shows or hides the levels that follow it
    if (t.matches('input[type=checkbox][id]')) {
      document.querySelectorAll('[data-gk-records-vlevels-follow]').forEach(function (n) {
        if (n.getAttribute('data-gk-records-vlevels-follow') === t.id) n.hidden = !t.checked;
      });
    }
    if (!t.matches('input[type=checkbox][data-gk-records-vlevel-check]')) return;
    var box = boxOf(t);
    if (!box) return;
    var step = t.getAttribute('data-gk-records-vlevel-check');
    // ticked again by hand: an open box for the level closes first, so a later untick opens a fresh one
    if (t.checked) { closeOpen(t.closest('.gk-records-vlevel')); restore(t); return; }
    var panel = box.querySelector('[data-gk-records-vlevels-move="' + step + '"]');
    if (panel) openMove(t, step, panel);
  });

  document.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('.gk-records-vlevels-popover [data-gk-records-vlevels-go], .gk-records-vlevels-popover [data-gk-records-vlevels-keep]');
    if (!b) return;
    e.preventDefault();
    var fb = b.closest('.gk-gui-stuff-popover-box');
    if (b.hasAttribute('data-gk-records-vlevels-keep')) keep(fb); else go(fb);
  });

  // Enter in the box's reason moves (Shift and Enter is a new line); never the form around it
  document.addEventListener('keydown', function (e) {
    var ta = e.target;
    if (e.key !== 'Enter' || e.shiftKey || !ta || ta.tagName !== 'TEXTAREA') return;
    var fb = ta.closest('.gk-records-vlevels-popover .gk-gui-stuff-popover-box');
    if (!fb) return;
    e.preventDefault();
    e.stopPropagation();
    go(fb);
  }, true);

  document.addEventListener('input', function (e) {
    var ta = e.target;
    var fb = ta && ta.closest && ta.closest('.gk-records-vlevels-popover .gk-gui-stuff-popover-box');
    if (!fb || ta.tagName !== 'TEXTAREA') return;
    var err = fb.querySelector('.gk-gui-stuff-reason-error');
    if (err) err.hidden = true;
    ta.removeAttribute('aria-invalid');
  });

  // a form drawn again after a refused save: the first level that is unticked with records and has nowhere to go, or
  // whose target or reason the save refused (data-gk-records-vlevel-refused), opens its box again, so the missing
  // choice is made where it was left (Avbryt ticks the level again)
  function reopen() {
    var boxes = document.querySelectorAll('.gk-records-vlevels[data-gk-records-vlevels] input[type=checkbox][data-gk-records-vlevel-check]');
    for (var i = 0; i < boxes.length; i++) {
      var cb = boxes[i];
      var li = cb.closest('.gk-records-vlevel');
      var step = cb.getAttribute('data-gk-records-vlevel-check');
      var move = li && hiddenField(li, 'move', step);
      if (cb.checked || !move || (li.closest('[hidden]'))) continue;
      if (move.value && cb.getAttribute('data-gk-records-vlevel-refused') !== '1') continue;
      var panel = boxOf(cb).querySelector('[data-gk-records-vlevels-move="' + step + '"]');
      if (panel) { openMove(cb, step, panel); return; }
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', reopen); else reopen();

  window.GkRecordsVlevels = { restore: restore };
})();
