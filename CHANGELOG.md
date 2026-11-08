# Changelog

All notable changes to GK Records are documented in this file.

## 1.05.000 (2026-11-06)

### Added

* The register of appearance settings: every GK plugin declares here what it changes in how Redmine's pages look or behave, each setting with its group, its levels (Off, Optional, Forced, or only Off and Forced for a setting that applies to all or none), its values and GK's proposal. Every setting is off until an administrator sets it, and a setting nobody declared is off. Every change by an administrator is an event on the setting with its reason. A person's own choices about the optional settings, and Like Redmine for me, are kept here too, each change an event of its own kind without a reason. A new table holds the levels, the values and the persons' choices. A number value outside its minimum, maximum or step is refused. A setting Redmine has its own setting for can give it with `core_link:`, as the words of its path and the path. On a person's page a setting's segment starts with Off only where its registration asks for it (`person_off:`). A value can have a quiet help text under it (`info:`).
* The event log can be filtered by the target's id, so that the history of one thing can be listed.
* At start, a plugin whose code registers an appearance setting that its `config/registrations.yml` does not list gets a line in the log.
* A function in the register can be declared on by default (`default: true` in `GkRecords::Features.register`); it is on until an administrator switches it off, and the first switch away from the default is an event like any other. Without the keyword a function is off until it is switched on, as before.
* An installation that has data when it gets the register keeps what it had chosen: a migration moves the levels, values and persons' choices that GK GUI Stuff, GK Core Stuff, GK Tags and GK People kept in their own places before, and the three functions that became appearance settings, into the register. Each level is the one the plugins answered before, also where nothing was stored, and what always held before (the instance band, the account menu's colours, the alignment, the space before AM and PM, the note of one's own mark) is set to Forced. A number outside its new limits is brought inside them. It runs once, only while the register is empty, and only for the plugins installed; a new installation gets nothing, and the old places are left as they were. Each row it writes is an event on the setting with the reason "migration", so that the history shows where the level came from.
* An installation's start choice for its appearance (`GkRecords::AppearanceSettings.start!`, with `as_redmine` or `gk_proposal`): carried out once, before anything is set, by the same fill as the links on the appearance page. Each level it changes is an event, and the choice itself is always one event for the installation, also when no level changed; each with the reason "installation".
* Appearance settings can have a list value (one entry per line, with a maximum number of entries and a pattern each entry must match) and an action value (a button under the setting that posts to the plugin's own address, with a confirmation and the form's reason). A setting can carry a warning, and a sharper warning when one of its values holds a given entry; with `reason_when_sharp:` a save that leaves it on in that state needs a reason. An optional setting can start off for each person (`person_default: 'off'`), and a setting can have only the levels Off and Optional, for what each person chooses and nobody forces. `record_on!` writes an event on a setting's row for something done to what it keeps.
* An appearance setting and a function can say where they change something on the pages and how the change gets there: `footprint:` (`anchors:`, `elements:`, `pages:`, `adds:`, `removes:`) and `applies:` (`class`, `server`, `script`, `data`, or `none` for no visible effect) on `GkRecords::AppearanceSettings.register` and `GkRecords::Features.register`, read with `footprint(key)` and `described?(key)`. A shared value has the footprints of the settings that read it, or its own when `register_shared` is given `footprint:` and `applies:`. An anchor may only use GK's own classes, ids and data attributes, Redmine's named purposeful ones and GK Core Stuff's marks (`GkRecords::Footprint`), its parts joined only by a space; an anchor that goes by a pseudo class, a child or a sibling, a bare tag or a part of a value is left out and logged. A page type is a key such as `core.issue`, kept as text.
* The check at start also logs the settings and functions whose footprint in the code differs from the plugin's `config/registrations.yml` (`footprints:`).
* Two scenario expectations: `records_reason_mode` reads the mode of the reasons for the whole installation or a place, and `records_feature_chosen` says whether one of the functions of GK Records is chosen.
* An event in the REST API has `reason_key`, the place its reason was asked for, when it has one.
* Events can be searched by free text (the field Search in the filter row, parameter `q`), also on a project's tab, in the CSV and through the API. The search looks in what the reader is shown: the kind, the target's name, the people she may see, the changes and the reason, and never in a private field or the name of a person or thing she may not see. All words must be found. One search looks through at most 10,000 events after the other filters; the page says so when it stopped there, and the API gives `search_cut`.

### Changed

* A function can be declared with the functions it goes with and the functions it requires. Several functions switched with one reason are one transaction, and the newest switch of each function is read in one query.
* A setting or function that needs GK Readup names it as GK Readup when the plugin is not installed.
* Add link in an issue's actions menu, Import document in the Documents tab's button row and the tracker form's Verification status check box are drawn through Redmine's hooks in those places (provided by GK Core Stuff) instead of being placed by script; without those hooks the row stands under the issue's description, the link at the end of the Documents tab, and the trackers are chosen on the plugin's settings page.
* The origin line of a read-in document is drawn under its category, date and custom fields through Redmine's hook there (provided by GK Core Stuff) instead of being moved by script; without that hook it stands at the end of the document page.
* The reason field on Redmine's settings pages is drawn just after Save through Redmine's hook there, in every settings tab and on a plugin's settings page (provided by GK Core Stuff). A settings form without that hook gets no reason field, and a required reason is then not asked for when that form is saved. Whether a save needs the reason is decided from the settings view it comes from (the General tab when no tab is named); a save naming a tab no settings view is known by still needs a required reason.
* The shared reason field takes a Save button marked `data-gk-reason-save` as the one it belongs to; without a mark, Enter and the field's button height use the form's default button.
* "with manifest" beside the export links: the zip icon is drawn by Redmine's icon helper, and the CSV link is recognized by its format class where Redmine's CSV dialog is on the page.
* The events page builds its folded detail rows directly instead of rewriting their markup.
* The reason label in a verification change's history entry keeps Redmine's paragraph spacing.
* Texts say Redmine and Redmine's where they said core, core's or the Swedish word for it.
* The zip icon "with manifest" beside the export formats and the check box in Redmine's CSV dialog are now off by default, also in an installation that upgrades. To get them back, set the new row The choice with manifest at exports under Administration > Appearance (GK GUI Stuff) to Forced or Optional. The log of exports, downloads and prints is not affected, and an address with `with_manifest=1` still gives the zip.

### Fixed

* Save works once a required reason is written after the form first stopped for it, in every form with a reason field and on the settings pages; Redmine's guard against double submission no longer blocks the second send.
* The table of places for reasons heads its first column with the plugin's name in the page's language instead of a missing translation.
* An upgrade from 1.03.000 or older now gets the table `gk_records_features`. Those versions used the migration number 011 for another migration, so the table was never made and saving a function's switch failed.
* Functions, appearance settings and reason modes read inside a transaction come from the table and leave the memory shared by the process's threads alone, so a request running at the same time can no longer make a code path see the old value. A save of several functions forgets the memory after its commit.
* The Events page has its name in the window title, with the target's name when it shows one target.
* A function's switch records the place its reason was asked for, as an appearance setting's change does, so that the place can offer the reason again. `Features.set!` and `Features.set_many!` take `reason_key:`.

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
