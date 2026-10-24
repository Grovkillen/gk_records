# Changelog

All notable changes to GK Records are documented in this file.

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
