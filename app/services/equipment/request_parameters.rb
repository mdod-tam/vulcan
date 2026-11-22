# frozen_string_literal: true

module Equipment
  module RequestParameters
    TABS = %w[needs_ordering ordered shipped].freeze

    module_function

    def return_context(source)
      source = source.with_indifferent_access if source.is_a?(Hash)
      return {} unless source.respond_to?(:each_pair)

      context = source[:return_context] || source
      return {} unless context.respond_to?(:each_pair)

      result = {}
      result[:tab] = context[:tab] if TABS.include?(context[:tab])
      %i[product_id application_id].each { |key| result[key] = context[key].to_s if context[key].to_s.match?(/\A[1-9]\d*\z/) }
      %i[manufacturer category program_group source search delivery].each do |key|
        value = context[key].to_s
        result[key] = value if value.present? && value.length <= 128
      end
      validate_filters!(result)
      result.compact
    end

    def validate_filters!(result)
      result[:category] = nil unless Product::CATEGORIES.key?(result[:category])
      result[:program_group] = nil unless Product::PROGRAM_GROUPS.key?(result[:program_group])
      result[:source] = nil unless %w[stock vendor].include?(result[:source])
      result[:delivery] = nil unless result[:tab] == 'shipped' && result[:delivery] == 'awaiting'
    end

    def record_versions(source)
      return {} unless source.respond_to?(:each_pair)

      source.each_pair.filter_map { |id, version| [id.to_s, version.to_s] if id.to_s.match?(/\A\d+\z/) && version.is_a?(String) }.to_h
    end
  end
end
