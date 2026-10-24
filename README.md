# GK Records

GK Records is one shared layer for notes, events and links on everything in Redmine that is not an issue, so that comments, reasons and history are kept in one place instead of in scattered columns. Other GK plugins register their models as targets, write events through it and show its lists on their pages.

## Features

Notes, events and links:

- Other plugins register their models as targets (who may see and write, how a thing is named and where it lives) and their own note, event and link kinds.
- Notes in light Markdown, with a configurable maximum length. Note kinds Comment and Reason, plus Occasion, Dispute, Question and Answer as a switchable function. Nothing is edited or deleted: a note is corrected by a new note (link "Corrects") and voided with a reason.
- Events with who, when, details and an optional reason. Origins other than a person (system, import, agent) can be marked.
- Links between things, with kinds that are symmetric or directed, and directed kinds that refuse circles. Built-in kinds: Corrects, Linked by hand (with a short reason), Same as, Not the same as, and Mentions (an issue number such as `#123` in a reason becomes a link to the issue).
- On issues: a Links tab in the issue history, with a row at the top that counts the links, and an Assessments tab when the issue has been assessed.
- Assessments of things, with assessment kinds registered by plugins or kept as data with names per language and a scale of outcomes.

Logs and administration:

- Administration > Events: the whole event log. With gk_queries it is a query with list, filters, CSV and API; without it the plugin's own page. Users with the global permission "View the whole event log" can open it; each target's own events follow who may see the target.
- Settings history: every changed setting, Redmine's own and every plugin's, is an event with who, when, before and after, and an optional "Reason for the change" field on the settings pages. Values that look like secrets are never written, only that they changed.
- Administration > Reasons: one mode for every place where a person is asked for a reason (Off, Optional or Required), for the whole installation and per place. The reason field suggests the person's latest and earlier reasons for that place.
- Administration > Readings: every import and sync run made by a GK plugin, with source, route, format, the name, size and SHA-256 of each file read (never the file), the mapping used, an optional manifest kept to the keys that describe the source, and counts (added, changed, unchanged, rejected). Fields set by a reading can show a short origin text beside them.

Other features:

- Verification status (Verified, Partly verified, Unverified, Hypothesis) on issues of chosen trackers and on assessments, with a column and filter in the issue list. Verified can only be reached through an approved review from a reviewing plugin; when the thing changes after the review it is shown as changed since the review.
- Read in documents: a zip with a document list (CSV) and the files is read into Redmine's Documents of a project and its subprojects, in two steps (preview, then run). Each row becomes a document with its file as an attachment, its origin and an event; files already there (the same SHA-256) are skipped unless chosen. A template for the document list can be downloaded. Requires the Documents permission to add documents in every target project.
- A global id (UUID version 7) for every registered thing, with origin and owner instance, resolvable as JSON at `/gk_records/identities/<gid>.json` for readers who may see the thing.
- Texts the system writes (not a person) are shown in the reader's language as they stood when written.
- Records never shows the name of a person the reader may not see by Redmine's own visibility rule; such a person is shown with a neutral text. Optionally, a small mark shows on people that some other active user may not see.
- One reader of the GK plugins' `config/registrations.yml` (what each plugin puts in the shared layers): a plugin asks for its own file, a layer for its section across every installed plugin, and a plugin's check at start lists the texts its file names that no language has.

## Requirements

- Redmine 6.0.0 or higher.
- Ruby 3.2 or later, the version your Redmine release runs on.
- PostgreSQL. Times are stored with their time zone (`timestamptz`), which the plugin relies on.

This plugin is developed and tested on Windows 11 with PostgreSQL only. That is a deliberate choice made for the maintainer's own convenience: the production system and the whole toolchain run there, and supporting other platforms and databases would cost time without adding anything for our own use. Times are stored with their time zone (`timestamptz`), so PostgreSQL is required. Apart from that, the Ruby code avoids needless Windows or PostgreSQL specific constructs, so it may well run on Linux, but that is untested and not supported.

GK plugins:

- Required: none.
- Optional: gk_queries (the event log as a query with filters, CSV and API, and the Links page as a relation view), gk_compat (core's colour variables on Redmine 6.0 and 6.1), gk_fields (translated list values in assessments), gk_gui_stuff (verification status and more note kinds as switchable functions; without it verification status is on and the extra note kinds are off), gk_icons (the icon for people others may not see), gk_people (the plugin's tables in the register of personal data processing), gk_revisions (the file name of the document list template), gk_scenarios (the plugin's scenario steps and checks).

## Installation

The plugin directory must be named `gk_records` (it is the plugin id): `plugins/gk_records/`.

1. Unpack the release package into Redmine's `plugins` directory.
2. Run the migrations: `bundle exec rake redmine:plugins:migrate RAILS_ENV=production`
3. Restart Redmine.

Uninstall:

1. `bundle exec rake redmine:plugins:migrate NAME=gk_records VERSION=0 RAILS_ENV=production`
2. Remove the `plugins/gk_records` directory and restart Redmine.

## Configuration

- Administration > Plugins > Configure (GK Records): longest note, show origin, mark people not everyone may see (off by default), the trackers that get verification status, and the assessment kinds kept as data.
- Administration > Reasons: the mode of every reason field.
- Administration > Roles and permissions: the global permission "View the whole event log".
- With gk_gui_stuff, Administration > Functions switches "More note kinds" (off by default) and "Verification status" (on by default).

## Usage

- Notes, events and links appear on the pages of the GK plugins that use GK Records.
- On an issue: the Links tab in the history, the Assessments tab when there are assessments, and the Verification status row on the chosen trackers.
- In a project with the Documents module: "Read in documents" on the Documents tab.
- Administrators: Administration > Events, Reasons and Readings.

## Changelog

See CHANGELOG.md.

## License

GPL-2.0-or-later, the same license as Redmine. Copyright (C) 2026 Jimmy Westberg. See the LICENSE file for the full text.
