# Changelog

All notable changes to GK Records are documented in this file.

## 1.04.000 (2026-10-28)

### Added

* The register of the GK plugins' functions (Administration > Functions in GK GUI Stuff shows it): every GK plugin declares its functions here, each is off until an administrator switches it on, and every switch is an event with its reason. A function nobody declared is off. The function More note kinds is declared here.
* The export log, moved here from GK Core Stuff: every export (Redmine's and the plugins'), every attachment downloaded and every print asked for in the browser is an event on what it is about, seen by those with the permission View exports and prints in the project, and a named export can be downloaded as a zip with manifest.json. It is switched on and off in this plugin's settings.

### Changed

* This version is installed anew and does not upgrade an earlier one: uninstall the earlier version first (migrate it down to 0 while its own files are in place), then install this one. Nothing is carried over from the earlier installation.
* Uninstalling (migrating the plugin down to 0) also removes the plugin's row in Redmine's settings.
* GK Core Stuff 1.01.000 or later is required: the line Verification in an issue's history is registered in its register of history lines instead of overriding Redmine's helper. Without GK Core Stuff the line is Redmine's own, and a warning is written to the log.
* README: the requirements are the GK plugins required and optional, without a list of versions to install together.

### Fixed

* With GK Compat older than 1.01.000 the REST API no longer fails with an error; the OAuth scopes are then not checked, as without GK Compat.

## 1.03.000 (2026-10-26)

### Changed

* The shared reason field: the link that opens it says "Add a reason", with Redmine's add icon, since it only opens the field; the form's own Save saves.
* Open, the field and its buttons stand in one light frame. The button is called "Use the reason", the suggestion button "Use the suggestion", the × "Remove the reason", and the placeholder is "Reason for the change".
* The field's buttons look and react to the pointer as Redmine's own buttons.
* In a table cell, the field and its buttons wrap inside the cell instead of running out of it.
* On the settings pages the reason link and its label stand on the same line as the Save button beside them.
* Settings page: the registered targets are a list with one row per target: what it is, its key, the plugin that registered it, and how many event and link kinds can be used on it (their names as a tooltip); the link kinds that go on every target are named once under the list. The assessment kinds made as data have a box of their own, shown when there are some.
* The shared reason field in a form stands on its own line under the form's Save and Cancel, so that Save and Cancel are always side by side; in a table's row it stays beside the row's Save.
* The shared reason field: the form's Save takes the reason that is written and sends it, as "Use the reason" does; Save is no longer dimmed while a reason is open. An empty optional reason never stops the form, and an empty required reason still does (the browser's own check, or the field's hint). "Use the reason" stays for whoever wants to see the reason as text first. The same on the settings pages.
* The hint for a required reason says "A reason is required: write it before saving."; the hint asking to click "Use the reason" first is gone.
* A required reason in a form stands open, so that it is seen to be required; an optional one is folded behind "Add a reason". In a table's row a required reason stays folded and opens with the cursor in it and a hint when the row is saved without it. Without JavaScript the field shows as before, and the server still refuses a missing reason.

### Fixed

* A required reason left empty, or too short, is asked for in the page's language instead of the browser's own message.

### Security

* REST API: an OAuth token reads the kinds, the readings list and the reasons only with the scope "Read record kinds, readings and reasons", and changes a reason mode only with "Change reason modes" (the last three stay for administrators); the event log no longer shows a token events of projects outside its scopes, and a linked issue's status is shown only when the token may see the issue.

## 1.02.000 (2026-10-24)

### Added

* One reader of the GK plugins' `config/registrations.yml`: a plugin asks for its own file, a layer for one section across every installed plugin, and a plugin's check at start writes to the log the texts its file names that no language has. A file is read again only when it has changed.

### Changed

* An issue without links no longer shows the tab Links. One who may link gets Add link in the issue's actions menu, which opens the issue with the tab, where the first link is made.

## 1.01.001 (2026-10-22)

### Fixed

* The change log: the entry for 1.01.000 is one entry with everything that version brought. As released, it listed the release candidates 1.01.000-rc1 and 1.01.000-rc2 under headings of their own, and under 1.01.000 only a fix made between the candidates. No code has changed since 1.01.000.

## 1.01.000 (2026-10-22)

### Added

* Events can be exported as CSV, from the event log page (with its filters) and from the list in GK Queries: the time in ISO 8601 with the zone, numbers with a point as the decimal sign, the language's column separator, UTF-8 with a byte order mark. Only what the reader may see is in the file; a hidden person is written as "(hidden)". The file is named by GK Revisions' rule when it is installed.
* A project module Events: a tab in the project with the project's events (and its subprojects' when Redmine shows subprojects' issues), for whoever has View events in the project.

### Changed

* View events is a permission per project in the module Events, instead of one for the whole installation. The event log under Administration shows a person who is not an administrator the events of the projects where the person has it; events without a project (settings, people) are shown to administrators only. On upgrade, the module is turned on in every active project where a member has a role with the permission (and in public projects when Non member or Anonymous has it), so no one loses a project's events.
* Reasons: when the whole installation is set to Off, Optional or Required, that mode holds for every place and the places cannot be changed one by one; their own choices show greyed with "Set by the whole installation". Only with Each place's default is the mode chosen per place. A place's own choice is kept and holds again when the installation is set back to Each place's default.

## 1.00.000 (2026-10-22)

* First release.
