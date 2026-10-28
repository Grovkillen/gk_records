# frozen_string_literal: true

# The event log as a query (plugins/queries plugin_queries: "records: noter och händelser över alla mål ...
# audit-loggen filtrerbar"). Registered with gk_queries when it is installed; listed at /gk_queries/records_events.
class GkRecordsEventQuery < Query
  self.queried_class = GkRecordsEvent
  self.layout = 'admin'

  # A column that groups on a real database column while it shows something else (core 7.0 groups on the
  # column's name; a label column such as kind_label groups on kind)
  class GroupColumn < QueryColumn
    def initialize(name, group_by:, **options)
      super(name, options.merge(groupable: true))
      @gk_group_by = group_by
    end

    def group_by_statement = @gk_group_by
  end

  # Who did it: a person the reader may not see is "en person du inte får se" in the list, CSV and JSON, and all
  # such people group and sort as one, so neither the heading nor the order tells them apart
  # (GkRecords::Visibility). Administrators see all, as in core.
  class UserColumn < GroupColumn
    def initialize(name, **options)
      super(name, group_by: nil, **options)
    end

    def group_by_statement = GkRecords::Visibility.user_id_sql("#{GkRecordsEvent.table_name}.user_id")
    def sortable = group_by_statement

    # CSV and JSON: a person shown whom some other user may not see is her name with the short text of the mark
    # (" (syns inte för alla)", setting mark_restricted_people); the list itself shows the icon (gk_queries_query_cell)
    def value_object(object)
      shown = GkRecords::Visibility.shown(object.user)
      # counted among those who see the event's thing (records_1021-SID-63)
      thing = object.target
      return shown unless shown.is_a?(::Principal) && GkRecords::Visibility.restricted_info(shown, on: thing)[:restricted]

      GkRecords::Visibility.marked_name(shown, on: thing)
    end
  end

  self.available_columns = [
    QueryColumn.new(:created_at, sortable: "#{GkRecordsEvent.table_name}.created_at", default_order: 'desc', caption: :field_created_on),
    GroupColumn.new(:kind_label, group_by: "#{GkRecordsEvent.table_name}.kind", sortable: "#{GkRecordsEvent.table_name}.kind", caption: :label_gk_records_kind),
    GroupColumn.new(:target_type, group_by: "#{GkRecordsEvent.table_name}.target_type", sortable: "#{GkRecordsEvent.table_name}.target_type", caption: :label_gk_records_target_type),
    QueryColumn.new(:target_label, caption: :label_gk_records_target),
    UserColumn.new(:user, caption: :label_gk_records_done_by),
    QueryColumn.new(:changes_text, caption: :label_gk_records_changes),
    QueryColumn.new(:reason_text, caption: :label_gk_records_note_reason),
    GroupColumn.new(:origin, group_by: "#{GkRecordsEvent.table_name}.origin", sortable: "#{GkRecordsEvent.table_name}.origin", caption: :field_gk_records_origin)
  ]

  def self.visible(*args)
    user = args.shift || User.current
    user.admin? || user.allowed_to_globally?(:gk_records_view_events) ? where('1=1') : where('1=0')
  end

  def initialize(attributes = nil, *args)
    super(attributes)
    self.filters ||= { 'created_at' => { operator: '>t-', values: ['30'] } }
  end

  def initialize_available_filters
    add_available_filter 'kind', type: :list, values: -> { GkRecords::Kinds.of(:event).map { |k| [k.label, k.key] } }, label: :label_gk_records_kind
    add_available_filter 'target_type', type: :list, values: -> { GkRecords::Targets.all.values.map { |t| [t.key, t.key] } }, label: :label_gk_records_target_type
    add_available_filter 'user_id', type: :list_optional, values: -> { author_values }, label: :field_user
    add_available_filter 'created_at', type: :date_past, label: :field_created_on
    add_available_filter 'origin', type: :list, values: GkRecordsNote::ORIGINS.map { |o| [o, o] }, label: :field_gk_records_origin
  end

  # The filter on user offers only the people the reader may see (core's list, and "me")
  def author_values
    values = super
    shown = GkRecords::Visibility.visible_user_ids(values.map { |v| v[1] }.reject { |id| id == 'me' })
    values.select { |v| v[1] == 'me' || shown.include?(v[1].to_s) }
  end

  # A filter value that is a person the reader may not see takes no part: with "is" it gives no hits, with "is
  # not" it removes nothing, so the number of hits never tells what a hidden person did
  def sql_for_user_id_field(field, operator, value)
    if %w[= !].include?(operator)
      value = GkRecords::Visibility.visible_user_ids(value)
      return(operator == '=' ? '1=0' : '1=1') if value.empty?
    end
    "(#{sql_for_field(field, operator, value, queried_table_name, field)})"
  end

  # created_at is the only date here, and has its zone (migration 002): core's date filter writes the day's bounds
  # in the reader's zone as text without an offset, which the database would read in its own session's zone, so they
  # are written in UTC with the offset written out
  def quoted_time(time, is_custom_filter)
    return super if is_custom_filter || !time.respond_to?(:utc)

    GkRecordsInstant.text(time)
  end
  private :quoted_time # as in core

  def visible?(user = User.current) = user.admin? || user.allowed_to_globally?(:gk_records_view_events)
  def editable_by?(user) = user&.admin?

  def default_columns_names = [:created_at, :kind_label, :target_label, :user, :changes_text, :reason_text]
  def default_sort_criteria = [['created_at', 'desc']]

  # 1.01.000: the log the reader may open, by the one rule (GkRecordsEvent.log_for), its order left to the query
  def base_scope
    (GkRecordsEvent.log_for(User.current)&.reorder(nil) || GkRecordsEvent.none).where(statement)
  end

  def results_scope(options = {})
    order_option = [group_by_sort_order, (options[:order] || sort_clause)].flatten.reject(&:blank?)
    base_scope.includes(:user, :reason_note).order(order_option).joins(joins_for_order_statement(order_option.join(',')))
  end

  # Cells with meaning, not bare strings: the kind as a tag, the target as a link, changes as before and after
  def gk_queries_query_cell(view, column, event)
    unless @gk_records_css
      @gk_records_css = true
      view.content_for(:header_tags) { view.stylesheet_link_tag('gk_records', plugin: 'gk_records') }
    end
    case column.name
    when :kind_label then view.content_tag('span', GkRecords::Kinds.label(:event, event.kind), class: 'gk-records-kindtag')
    when :target_label then view.gk_records_ref_link(event.target_type, event.target_id)
    when :changes_text
      d = view.gk_records_details(event)
      d.present? ? view.content_tag('ul', d, class: 'gk-records-diff') : ''
    when :reason_text then view.gk_records_reason(event)
    when :user then view.gk_records_who(event)
    end
  end
end
