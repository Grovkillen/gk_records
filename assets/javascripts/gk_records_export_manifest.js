// export_log: the choice where exports are offered. A check box "med manifest" in core's CSV dialog (#csv-export-form,
// and any form marked data-gk-records-export), and a second link, core's zip icon with "med manifest" in its
// tooltip, beside each export link in "Also available in" (p.other-formats) and beside any link marked
// data-gk-records-export. The choice adds
// with_manifest=1; the server sends a zip with the file and manifest.json. Without the choice nothing changes. Texts
// from the locale (meta#gk-records-export-manifest). No jQuery.
(function () {
  'use strict';

  var meta = document.getElementById('gk-records-export-manifest');
  if (!meta) return;
  var label = meta.getAttribute('data-label') || '';
  var title = meta.getAttribute('data-title') || '';

  function withManifest(href) {
    var u = new URL(href, window.location.href);
    u.searchParams.set('with_manifest', '1');
    return u.toString();
  }

  function addCheckbox(form) {
    if (form.querySelector('input[name="with_manifest"]')) return;
    var p = document.createElement('p');
    var lab = document.createElement('label');
    var cb = document.createElement('input');
    cb.type = 'checkbox';
    cb.name = 'with_manifest';
    cb.value = '1';
    lab.title = title;
    lab.appendChild(cb);
    lab.appendChild(document.createTextNode(' ' + label));
    p.appendChild(lab);
    var buttons = form.querySelector('p.buttons');
    form.insertBefore(p, buttons || null);
  }

  // core's zip icon from the page's own sprite (the one core's icons on the page use); null when there is none
  function zipIcon() {
    var use = document.querySelector('svg use[href*="#icon--"]');
    if (!use) return null;
    var ns = 'http://www.w3.org/2000/svg';
    var svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('class', 's18 icon-svg');
    svg.setAttribute('aria-hidden', 'true');
    var u = document.createElementNS(ns, 'use');
    u.setAttribute('href', use.getAttribute('href').split('#')[0] + '#icon--application-zip');
    svg.appendChild(u);
    return svg;
  }

  function addLink(a) {
    if (a.dataset.gkRecordsManifest || a.classList.contains('atom')) return;
    var href = a.getAttribute('href');
    // core's CSV link opens the dialog (the check box is there)
    if (!href || href.charAt(0) === '#' || a.hasAttribute('onclick') || a.hasAttribute('data-method')) return;
    a.dataset.gkRecordsManifest = '1';
    var m = document.createElement('a');
    m.href = withManifest(a.href);
    // a small zip icon beside the format; what it downloads is in the tooltip, and the label is read aloud
    var icon = zipIcon();
    if (icon) { m.appendChild(icon); m.className = 'gk-records-manifest-link icon-only'; } else { m.textContent = label; m.className = 'gk-records-manifest-link'; }
    m.title = label + ': ' + title;
    m.setAttribute('aria-label', label + ': ' + title);
    m.dataset.gkRecordsManifest = '1';
    var span = document.createElement('span');
    span.className = 'gk-records-manifest';
    span.appendChild(document.createTextNode(' '));
    span.appendChild(m);
    a.insertAdjacentElement('afterend', span);
  }

  function run() {
    document.querySelectorAll('#csv-export-form, form[data-gk-records-export]').forEach(addCheckbox);
    document.querySelectorAll('p.other-formats a, a[data-gk-records-export]').forEach(addLink);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
})();
