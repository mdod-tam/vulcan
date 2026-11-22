# frozen_string_literal: true

module Admin
  # Buttons and state labels for the email controls on the email templates page.
  module EmailDeliveryHelper
    # pair is a ControlPanel::Pair or a { name:, format: } hash.
    def email_template_pair_anchor(pair)
      name, format = pair.is_a?(Hash) ? pair.values_at(:name, :format) : [pair.name, pair.format]
      "template-#{name}-#{format}".parameterize
    end

    # A button that turns a control on or off. It carries the state the admin saw, so a newer
    # change by someone else is not silently reversed, and an operation id, so a resubmitted
    # form is applied once.
    def email_control_button(label:, url:, enabled:, version:, extra_params: {})
      return tag.p(email_delivery_t('missing_control_help'), class: 'text-sm text-danger-800 max-w-prose') if enabled.nil?

      target = !enabled
      master = extra_params[:control] == EmailDelivery::ALL_CONTROL
      key = if master
              target ? 'resume_correspondence' : 'pause_correspondence'
            else
              target ? 'turn_on' : 'turn_off'
            end
      channel = EmailDelivery::CHANNEL_CONTROLS.key(extra_params[:control])
      confirmation = channel && !target ? "turn_off_#{channel}_confirm" : "#{key}_confirm"
      button_to email_delivery_t(key), url,
                method: :patch,
                params: extra_params.merge(enabled: target, expected_version: version, operation_id: SecureRandom.uuid),
                class: email_control_button_class(target, master: master),
                aria: { label: master ? email_delivery_t(key) : email_delivery_t("#{key}_aria", label: label) },
                form: { class: 'inline', data: { turbo_confirm: email_delivery_t(confirmation, label: label) } }
    end

    def email_control_state_badge(saved_enabled:, suppressed_by:, category: nil, mixed: false)
      tag.span(class: 'inline-flex flex-wrap items-center gap-1 text-xs') do
        if saved_enabled && suppressed_by
          safe_join([blocked_state_badge(suppressed_by, category), tag.span(email_delivery_t('saved_on'), class: 'text-gray-700')])
        else
          saved_state_badge(saved_enabled, mixed)
        end
      end
    end

    def email_delivery_t(key, **)
      t("admin.email_delivery.#{key}", **, locale: :en)
    end

    def email_bulk_template_button(enabled:, counts:, version:)
      total = counts.values.sum
      change_count = total - counts.fetch(enabled ? :on : :off, 0)
      key = enabled ? 'enable_all' : 'disable_all'
      url = enabled ? bulk_enable_admin_email_templates_path : bulk_disable_admin_email_templates_path

      button_to email_delivery_t("#{key}_groups", count: total), url,
                method: :patch, params: { operation_id: SecureRandom.uuid, expected_version: version },
                disabled: change_count.zero?, class: enabled ? 'btn btn-secondary' : 'btn btn-danger-outline',
                form: { data: { turbo_confirm: email_delivery_t("#{key}_confirm", count: change_count) } }
    end

    def email_bulk_template_flash(result, enabled:)
      return { alert: email_delivery_t('bulk_stale') } if result.status == :stale
      return { notice: email_delivery_t('already_applied') } if result.status == :already_applied

      message = email_delivery_t('bulk_result', count: result.changed_count)
      message += " #{email_delivery_t('bulk_cancellation')}" if !enabled && result.changed_count.positive?
      { notice: message }
    end

    def email_control_flash(result, label:)
      enabled = Array(result.control).all?(&:enabled)
      state = email_delivery_t(enabled ? 'state_on' : 'state_off').downcase
      case result.status
      when :changed
        message = email_delivery_t('changed', label: label, state: state)
        message += " #{email_delivery_t('canceled_pending')}" unless enabled
        { notice: message }
      when :unchanged then { notice: email_delivery_t('unchanged', label: label, state: state) }
      when :stale then { alert: email_delivery_t('stale', label: label) }
      else { notice: email_delivery_t('already_applied') }
      end
    end

    def email_template_link_class
      'text-sm text-primary-700 hover:text-primary-900'
    end

    private

    def saved_state_badge(saved_enabled, mixed)
      return mixed_state_badge if mixed

      state = if saved_enabled.nil?
                'state_missing'
              else
                saved_enabled ? 'state_on' : 'state_off'
              end
      variant = if saved_enabled.nil?
                  :attention
                else
                  saved_enabled ? :success : :danger
                end
      badge(email_delivery_t(state), variant)
    end

    def mixed_state_badge
      safe_join([badge(email_delivery_t('state_mixed'), :attention), tag.span(email_delivery_t('pair_mixed'), class: 'text-warning-800')], ' ')
    end

    def blocked_state_badge(suppressed_by, category)
      return badge(email_delivery_t('blocked_by_master'), :attention) if suppressed_by == :all_disabled
      return badge(email_delivery_t('state_missing'), :attention) if suppressed_by == :configuration_error

      reason = EmailDelivery::ControlPanel.reason_text(suppressed_by, category: category)
      tag.span(email_delivery_t('suppressed_prefix', reason: reason), class: 'rounded-md bg-warning-50 px-2 py-0.5 text-warning-900')
    end

    def email_control_button_class(target, master:)
      return target ? 'btn btn-primary' : 'btn btn-danger-outline' if master

      target ? 'btn btn-sm btn-secondary' : 'btn btn-sm btn-danger-outline'
    end
  end
end
