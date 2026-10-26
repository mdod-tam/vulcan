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
      key = target ? 'turn_on' : 'turn_off'
      button_to email_delivery_t(key), url,
                method: :patch,
                params: extra_params.merge(enabled: target, expected_version: version, operation_id: SecureRandom.uuid),
                class: email_control_button_class(target),
                aria: { label: email_delivery_t("#{key}_aria", label: label) },
                form: { class: 'inline' },
                data: { turbo_confirm: email_delivery_t("#{key}_confirm", label: label) }
    end

    def email_control_state_badge(saved_enabled:, suppressed_by:, category: nil, mixed: false)
      tag.span(class: 'inline-flex flex-wrap items-center gap-1 text-xs') do
        safe_join([saved_state_badge(saved_enabled, mixed), suppression_note(saved_enabled, suppressed_by, category)].compact)
      end
    end

    def email_delivery_t(key, **)
      t("admin.email_delivery.#{key}", **, locale: :en)
    end

    def email_bulk_button_class(turning_on)
      "btn #{email_button_colors(turning_on)}"
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
      state_badge = badge(email_delivery_t(state), variant)
      return state_badge unless mixed

      safe_join([state_badge, tag.span(email_delivery_t('pair_mixed'), class: 'text-warning-800')], ' ')
    end

    def suppression_note(saved_enabled, suppressed_by, category)
      return unless saved_enabled && suppressed_by

      reason = EmailDelivery::ControlPanel.reason_text(suppressed_by, category: category)
      tag.span(email_delivery_t('suppressed_prefix', reason: reason), class: 'text-warning-800')
    end

    def email_control_button_class(target)
      "btn btn-sm #{email_button_colors(target)}"
    end

    # Turning a control on is a success action and turning it off is a danger action.
    def email_button_colors(turning_on)
      turning_on ? 'btn-success' : 'btn-danger'
    end
  end
end
