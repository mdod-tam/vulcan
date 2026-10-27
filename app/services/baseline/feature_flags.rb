# frozen_string_literal: true

module Baseline
  # Checked-in feature flag defaults. Communication controls change only through EmailDelivery::ControlWriter,
  # which cancels pending messages when a control turns off.
  module FeatureFlags
    GENERAL_DEFAULTS = { 'vouchers_enabled' => false, 'dcf_auto_request_certification' => false }.freeze
    CONTROL_DEFAULTS = EmailDelivery::CONTROL_NAMES.index_with(true).freeze
    DEFAULTS = GENERAL_DEFAULTS.merge(CONTROL_DEFAULTS).freeze

    def self.reset!(actor:)
      GENERAL_DEFAULTS.each { |name, enabled| FeatureFlag.find_or_initialize_by(name: name).update!(enabled: enabled) }

      operation_id = SecureRandom.uuid
      CONTROL_DEFAULTS.each do |name, enabled|
        FeatureFlag.find_or_create_by!(name: name) { |flag| flag.enabled = enabled }
        result = EmailDelivery::ControlWriter.set(name: name, enabled: enabled, actor: actor, operation_id: "#{operation_id}:#{name}")
        raise "Could not reset #{name} (#{result.status})" unless result.changed? || result.status == :unchanged
      end
    end
  end
end
