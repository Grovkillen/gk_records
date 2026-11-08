# frozen_string_literal: true

require 'yaml'

module GkRecords
  # Registrations. The one reader of the plugins' config/registrations.yml: what each GK plugin puts in
  # the shared layers (menu rows, waves, records' targets and kinds, folds, view states and the rest), written as a
  # checked print of what its code registers. A plugin's init.rb asks for its own file here, and a layer asks for its
  # section across every plugin; nobody parses the files on their own.
  # * for(plugin) gives a plugin's file as a hash ({} when it has none or it cannot be read);
  # * section(name) gives { plugin_id => value } for every installed plugin whose file has the section;
  # * missing_texts(plugin) gives the locale keys the file names (label, word, done) that no locale has, for the
  #   plugin's own check at start; check!(plugin) writes them to the log, with the appearance settings its
  #   code registered that the file does not list and the rows whose footprint or applies the file prints otherwise.
  # A file is read again only when it has changed (its time and size).
  module Registrations
    TEXT_FIELDS = %w[label word done].freeze

    @cache = {}

    class << self
      def for(plugin)
        p = ::Redmine::Plugin.find(plugin.to_sym)
        read(File.join(p.directory.to_s, 'config', 'registrations.yml'))
      rescue ::Redmine::PluginNotFound
        {}
      end

      def section(name)
        ::Redmine::Plugin.all.each_with_object({}) do |p, h|
          y = self.for(p.id)
          h[p.id.to_s] = y[name.to_s] if y.key?(name.to_s)
        end
      end

      def missing_texts(plugin)
        keys = []
        walk(self.for(plugin)) { |k, v| keys << v.to_s if TEXT_FIELDS.include?(k.to_s) && v.to_s.match?(/\A[a-z][a-z0-9_]*\z/) }
        keys.uniq.reject { |k| ::I18n.exists?(k, :en) }
      end

      # The appearance settings a plugin's code registered that its file does not list under appearance_settings
      def unlisted_appearance_settings(plugin)
        return [] unless defined?(AppearanceSettings)

        listed = Array(self.for(plugin)['appearance_settings']).filter_map { |r| r.is_a?(Hash) ? r['key'].to_s : nil }
        AppearanceSettings.declared.values.select { |r| r.plugin == plugin.to_s }.map(&:key) - listed
      end

      # The settings and functions of a plugin whose footprint or applies in the code differs from its file's print under
      # footprints: ({ key => { applies:, footprint: } }, which the pipeline's footprint check reads): [key, ...]. A row
      # with neither in the code and none in the file is the same.
      def footprint_mismatches(plugin)
        printed = self.for(plugin)['footprints']
        printed = {} unless printed.is_a?(Hash)
        rows = (defined?(AppearanceSettings) ? AppearanceSettings.declared.values : []) +
               (defined?(Features) ? Features.declared.values : [])
        # a shared value is not printed under footprints:, also when it has a footprint of its own
        rows.select { |r| r.plugin == plugin.to_s && !(r.respond_to?(:shared?) && r.shared?) }
            .reject { |r| same_footprint?(r, printed[r.key] || {}) }.map(&:key)
      end

      def same_footprint?(row, printed)
        printed = {} unless printed.is_a?(Hash)
        fp = Footprint.stable(Footprint.normalize(printed['footprint'], row.key))
        fp == row.footprint && Footprint.applies(printed['applies'], row.key) == Array(row.applies)
      rescue ArgumentError
        false
      end

      def check!(plugin)
        missing = missing_texts(plugin)
        Rails.logger.warn("[gk_records] registrations.yml of #{plugin}: no text for #{missing.join(', ')}") if missing.any?
        unlisted = unlisted_appearance_settings(plugin)
        Rails.logger.warn("[gk_records] registrations.yml of #{plugin}: appearance settings not listed: #{unlisted.join(', ')}") if unlisted.any?
        differs = footprint_mismatches(plugin)
        Rails.logger.warn("[gk_records] registrations.yml of #{plugin}: footprint or applies not as the code says: #{differs.join(', ')}") if differs.any?
        missing
      rescue StandardError => e
        Rails.logger.warn("[gk_records] registrations.yml of #{plugin} not checked: #{e.class} #{e.message}")
        []
      end

      private

      def read(file)
        return {} unless File.file?(file)

        stamp = [File.mtime(file).to_f, File.size(file)]
        hit = @cache[file]
        return hit[:data] if hit && hit[:stamp] == stamp

        y = YAML.safe_load(File.read(file, encoding: 'UTF-8'))
        data = y.is_a?(Hash) ? y : {}
        @cache[file] = { stamp: stamp, data: data }
        data
      rescue StandardError => e
        Rails.logger.warn("[gk_records] #{file} not read: #{e.class} #{e.message}")
        {}
      end

      def walk(node, &block)
        case node
        when Hash then node.each { |k, v| v.is_a?(Hash) || v.is_a?(Array) ? walk(v, &block) : yield(k, v) }
        when Array then node.each { |v| walk(v, &block) }
        end
      end
    end
  end
end
