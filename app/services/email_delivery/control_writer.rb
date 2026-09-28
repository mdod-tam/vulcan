# frozen_string_literal: true

module EmailDelivery
  # The only writer for email controls and template enablement. Turning a control or template pair
  # off bumps its generation in the same transaction, which cancels every email captured under the
  # old generation. Turning it on never restores an old generation. Each operation id is applied
  # at most once.
  class ControlWriter
    AUDIT_ACTION = 'email_control_changed'

    Result = Data.define(:status, :control) do
      def changed? = status == :changed
      def stale? = status == :stale
    end

    # A form carries the version it was rendered from. On/off plus generation changes on every
    # turn-off, so a form loaded before someone else turned a control off and on again is stale.
    def self.version_for(control_or_rows)
      Array(control_or_rows).sort_by(&:id).map { |row| "#{row.id}:#{row.enabled}:#{row.delivery_generation}" }.join(',')
    end

    # expected_version (or expected_enabled) is what the admin saw; a newer change by someone else wins.
    def self.set(name:, enabled:, actor:, operation_id:, expected_enabled: nil, expected_version: nil)
      raise ArgumentError, "Unknown email control: #{name}" unless CONTROL_NAMES.include?(name)
      raise ArgumentError, 'operation_id is required' if operation_id.blank?

      FeatureFlag.transaction do
        control = FeatureFlag.lock.find_by(name: name) || raise(ConfigurationError, "Missing #{name} control")
        next Result.new(status: :already_applied, control: control) if applied?(operation_id, AUDIT_ACTION)
        next Result.new(status: :stale, control: control) if stale?(control, expected_enabled, expected_version)
        next Result.new(status: :unchanged, control: control) if control.enabled == enabled

        apply(control, enabled: enabled, actor: actor, operation_id: operation_id)
      end
    end

    TEMPLATE_AUDIT_ACTION = 'email_template_pair_toggled'

    # Turns every locale of one template name and format on or off together.
    # expected_enabled is whether the admin saw the pair as on.
    def self.set_template_pair(name:, format:, enabled:, actor:, operation_id:, # rubocop:disable Metrics/ParameterLists
                               expected_enabled: nil, expected_version: nil)
      raise ArgumentError, 'operation_id is required' if operation_id.blank?
      raise ArgumentError, "#{name} is a shared fragment, not a sendable template" if EmailTemplate.fragment_name?(name)

      EmailTemplate.transaction do
        rows = EmailTemplate.lock.where(name: name, format: format).order(:id).to_a
        raise ActiveRecord::RecordNotFound, "No #{format} template named #{name}" if rows.empty?
        next Result.new(status: :already_applied, control: rows) if applied?(operation_id, TEMPLATE_AUDIT_ACTION)

        next Result.new(status: :stale, control: rows) if stale?(rows, expected_enabled, expected_version)
        next Result.new(status: :unchanged, control: rows) if rows.all? { |row| row.enabled == enabled }

        apply_template_pair(rows, enabled: enabled, actor: actor, operation_id: operation_id)
      end
    end

    def self.apply_template_pair(rows, enabled:, actor:, operation_id:)
      old_values = rows.to_h { |row| [row.locale, row.enabled] }
      rows.each do |row|
        row.delivery_generation += 1 unless enabled
        row.email_control_write = true
        row.update!(enabled: enabled, updated_by: actor)
      end
      AuditEventService.log(
        action: TEMPLATE_AUDIT_ACTION,
        actor: actor,
        auditable: rows.first,
        metadata: {
          operation_id: operation_id,
          email_template_name: rows.first.name,
          email_template_format: rows.first.format,
          old_values: old_values,
          new_value: enabled,
          canceled_pending: !enabled
        }
      )
      Result.new(status: :changed, control: rows)
    end
    private_class_method :apply_template_pair

    def self.apply(control, enabled:, actor:, operation_id:)
      canceling = control.enabled && !enabled
      control.delivery_generation += 1 if canceling
      control.email_control_write = true
      control.update!(enabled: enabled)
      AuditEventService.log(
        action: AUDIT_ACTION,
        actor: actor,
        auditable: control,
        metadata: {
          operation_id: operation_id,
          control: control.name,
          old_value: !enabled,
          new_value: enabled,
          delivery_generation: control.delivery_generation,
          canceled_pending: canceling
        }
      )
      Result.new(status: :changed, control: control)
    end
    private_class_method :apply

    def self.stale?(control_or_rows, expected_enabled, expected_version)
      return version_for(control_or_rows) != expected_version if expected_version.present?
      return false if expected_enabled.nil?

      Array(control_or_rows).all?(&:enabled) != expected_enabled
    end
    private_class_method :stale?

    def self.applied?(operation_id, action)
      Event.where(action: action).exists?(["metadata->>'operation_id' = ?", operation_id.to_s])
    end
    private_class_method :applied?
  end
end
