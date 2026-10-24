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
  #   plugin's own check at start (T-REG, 8.1); check!(plugin) writes them to the log.
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

      def check!(plugin)
        missing = missing_texts(plugin)
        Rails.logger.warn("[gk_records] registrations.yml of #{plugin}: no text for #{missing.join(', ')}") if missing.any?
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
