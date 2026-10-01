# frozen_string_literal: true

module Admin
  # All, channel and category controls use EmailDelivery::ControlWriter.
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
      redirect_back_to_controls(**helpers.email_control_flash(result, label: control_label(name)))
    rescue EmailDelivery::ConfigurationError
      redirect_back_to_controls(alert: t('admin.email_delivery.configuration_error', locale: :en))
    end

    private

    def boolean_param(key)
      ActiveModel::Type::Boolean.new.cast(params.require(key))
    end

    def control_label(name)
      return t('admin.email_delivery.global_label', locale: :en) if name == EmailDelivery::ALL_CONTROL
      return EmailDelivery::ControlPanel.channel_label(EmailDelivery::CHANNEL_CONTROLS.key(name)) if
        EmailDelivery::CHANNEL_CONTROLS.value?(name)

      EmailDelivery::ControlPanel.category_label(name.delete_prefix(EmailDelivery::CATEGORY_PREFIX))
    end

    def redirect_back_to_controls(**flash)
      redirect_to admin_email_templates_path(anchor: 'email-delivery'), **flash
    end
  end
end
