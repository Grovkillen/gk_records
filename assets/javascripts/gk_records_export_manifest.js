// export_log: the choice where exports are offered. A check box "med manifest" in core's CSV dialog (#csv-export-form,
// and any form marked data-gk-records-export), and a second link, core's zip icon with "med manifest" in its
// tooltip, beside each export link in "Also available in" (p.other-formats) and beside any link marked
// data-gk-records-export. The choice adds
// with_manifest=1; the server sends a zip with the file and manifest.json. Without the choice nothing changes. Texts
// from the locale (meta#gk-records-export-manifest). Loaded only while the row under Appearance is on. No jQuery.
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
    p.className = 'gk-records-manifest-choice';
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

  // core's zip icon as core's helper drew it into the page's head (template#gk-records-export-manifest-icon, the
  // running series' sprite); null when there is none
  function zipIcon() {
    var t = document.getElementById('gk-records-export-manifest-icon');
    var svg = t && t.content && t.content.firstElementChild;
    return svg ? svg.cloneNode(true) : null;
  }

  // Core marks each link in "Also available in" with its format as class (OtherFormatsBuilder: atom, csv, pdf ...):
  // the feed is no download, and where core's CSV dialog is on the page (#csv-export-options) the CSV link opens it,
  // and the check box is there
  function addLink(a) {
    if (a.dataset.gkRecordsManifest || a.classList.contains('atom')) return;
    if (a.classList.contains('csv') && !a.hasAttribute('data-gk-records-export') && document.getElementById('csv-export-options')) return;
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
