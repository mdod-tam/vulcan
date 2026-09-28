# frozen_string_literal: true

module Admin
  # The master and category email controls. Every change goes through EmailDelivery::ControlWriter.
  class EmailDeliveryControlsController < BaseController
    def update
      name = params.require(:control).to_s
      return redirect_back_to_controls(alert: t('alerts.invalid_request', default: 'Unknown email control.')) unless
        EmailDelivery::CONTROL_NAMES.include?(name)

      result = EmailDelivery::ControlWriter.set(
        name: name,
        enabled: boolean_param(:enabled),
        actor: current_user,
        operation_id: params.require(:operation_id),
        expected_enabled: params.key?(:expected_enabled) ? boolean_param(:expected_enabled) : nil,
        expected_version: params[:expected_version].presence
      )
      redirect_back_to_controls(**flash_for(result, control_label(name)))
    end

    private

    def boolean_param(key)
      ActiveModel::Type::Boolean.new.cast(params.require(key))
    end

    def control_label(name)
      return t('admin.email_delivery.global_label', locale: :en) if name == EmailDelivery::GLOBAL_CONTROL

      EmailDelivery::ControlPanel.category_label(name.delete_prefix(EmailDelivery::CATEGORY_PREFIX))
    end

    def flash_for(result, label)
      state = t(result.control.enabled ? 'admin.email_delivery.state_on' : 'admin.email_delivery.state_off', locale: :en).downcase
      case result.status
      when :changed
        message = t('admin.email_delivery.changed', label: label, state: state, locale: :en)
        message += " #{t('admin.email_delivery.canceled_pending', locale: :en)}" unless result.control.enabled
        { notice: message }
      when :unchanged then { notice: t('admin.email_delivery.unchanged', label: label, state: state, locale: :en) }
      when :stale then { alert: t('admin.email_delivery.stale', label: label, locale: :en) }
      else { notice: t('admin.email_delivery.already_applied', locale: :en) }
      end
    end

    def redirect_back_to_controls(**flash)
      redirect_to admin_email_templates_path(anchor: 'email-delivery'), **flash
    end
  end
end
