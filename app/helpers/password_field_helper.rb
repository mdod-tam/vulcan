# frozen_string_literal: true

module PasswordFieldHelper
  def password_visibility_data(timeout: 5000)
    {
      controller: 'visibility',
      visibility_timeout_value: timeout,
      visibility_hidden_status_value: t('password_visibility.status.hidden'),
      visibility_visible_status_value: t('password_visibility.status.visible'),
      visibility_show_label_value: t('password_visibility.toggle.show'),
      visibility_hide_label_value: t('password_visibility.toggle.hide')
    }
  end

  # Element ids for shared/_password_field, derived from the input id so two fields on one page
  # never share a status, hint, or error element.
  def password_field_ids(input_id)
    { input: input_id, status: "password-visibility-status-#{input_id}",
      hint: "#{input_id}-hint", error: "#{input_id}-error" }
  end
end
