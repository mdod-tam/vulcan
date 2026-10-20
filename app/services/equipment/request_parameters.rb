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
      %i[product_id vendor_id].each do |key|
        result[key] = context[key].to_s if context[key].to_s.match?(/\A[1-9]\d*\z/)
      end
      result
    end

    def record_versions(source)
      return {} unless source.respond_to?(:each_pair)

      source.each_pair.filter_map { |id, version| [id.to_s, version.to_s] if id.to_s.match?(/\A\d+\z/) && version.is_a?(String) }.to_h
    end
  end
end
