# frozen_string_literal: true

require 'csv'

module GkRecords
  # The event log as CSV (records 1.01.000): the same rows the reader sees on the page, in a form a spreadsheet and a
  # script read alike. Times are ISO 8601 with the zone, in the reader's time zone; numbers have a point as the decimal
  # sign; the column separator is the language's (core's general_csv_separator); UTF-8 with a byte order mark, so that
  # Excel reads å, ä and ö. What the reader may not see is left out as on the page: a hidden person is "(dold)", a hidden
  # thing has no name, a private field is empty (GkRecordsEvent#as_api_json). Used by the page and by the list in
  # gk_queries, so the file is the same both ways.
  module EventsCsv
    module_function

    NAME_KIND = 'records.events'
    # the byte order mark (U+FEFF) Excel needs to read the file as UTF-8
    BOM = [0xFEFF].pack('U').freeze
    COLUMNS = %w[time kind kind_text target_type target_id target project person changes reason].freeze

    def generate(events, viewer = User.current)
      events = events.to_a
      Verification.preload_places(events) if defined?(Verification) && Verification.respond_to?(:preload_places)
      projects = ::Project.where(id: events.map(&:project_id).compact.uniq).pluck(:id, :identifier).to_h
      zone = viewer.time_zone || ::Time.zone
      body = ::CSV.generate(col_sep: ::I18n.t(:general_csv_separator, default: ','), row_sep: "\r\n") do |csv|
        csv << COLUMNS.map { |c| ::I18n.t("label_gk_records_csv_#{c}") }
        events.each { |e| csv << row(e, viewer, zone, projects) }
      end
      BOM + body
    end

    def row(event, viewer, zone, projects)
      j = event.as_api_json(viewer)
      thing = target_of(event, viewer)
      # the offset always written out (+00:00, never Z), so a reader sees the zone the time is in
      [event.created_at.in_time_zone(zone).strftime('%Y-%m-%dT%H:%M:%S%:z'), event.kind, event.kind_label, event.target_type, event.target_id,
       thing ? Targets.label(thing) : '', projects[event.project_id].to_s, person(event, j), changes(j[:details], event, viewer),
       j[:reason].to_s]
    end

    def target_of(event, viewer)
      obj = Targets.find(event.target_type)&.model_class&.find_by(id: event.target_id)
      obj && Targets.visible?(obj, viewer) ? obj : nil
    rescue StandardError
      nil
    end

    def person(event, json)
      return hidden if json[:user_hidden]

      event.user&.login.to_s
    end

    # One line per field: "field: before -> after", or "field: value"; a change of the verification status in the
    # words of its place ("Verifieringsstatus: Hypotes -> Delvis verifierad"), and the field that says the event was
    # written while the gate to GK GUI Stuff was closed in its words ("GK GUI Stuff: missing", Gate.line)
    # A kind registered with rows: (Kinds.event_rows) is said in its owner's words, "label: from -> to", from the details
    # the viewer may see
    def changes(details, event = nil, viewer = nil)
      return '' unless details.is_a?(Hash)

      own = event.respond_to?(:change_details) && Kinds.respond_to?(:event_rows) ? Kinds.event_rows(event.kind, event.change_details(viewer || User.current), viewer) : nil
      return own.map { |r| Kinds.row_text(r, '->') }.join("\n") if own

      details.map do |field, change|
        if event.respond_to?(:verification_status?) && event.verification_status?(field, change)
          Verification.change_line(event, change[0], change[1], '->')
        elsif Gate.detail?(field, change)
          Gate.line(change)
        elsif change.is_a?(Array) && change.size == 2
          "#{field}: #{value(change[0])} -> #{value(change[1])}"
        else
          "#{field}: #{value(change)}"
        end
      end.join("\n")
    end

    # A number with a point, a person as the name or "(dold)", the rest as it is
    def value(v)
      case v
      when Hash
        h = v.transform_keys(&:to_s)
        h['hidden'] ? hidden : (h['name'] || h['principal']).to_s
      when Float, BigDecimal then v.to_s
      when nil then ''
      else v.to_s
      end
    end

    def hidden = ::I18n.t(:text_gk_records_csv_hidden)

    def file_name(project: nil)
      return ::GkRevisions::Names.file_name(NAME_KIND, {}, project: project) if defined?(::GkRevisions::Names)

      "records_events_#{::Time.current.strftime('%Y%m%dT%H%M%S')}.csv"
    end

    def declare_names!
      return unless defined?(::GkRevisions::Names)

      ::GkRevisions::Names.register(NAME_KIND, plugin: :gk_records, label_key: :label_gk_records_name_events, ext: 'csv')
    end
  end
end
