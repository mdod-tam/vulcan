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
end
