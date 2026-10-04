# frozen_string_literal: true

require 'test_helper'

class PasswordFieldHelperTest < ActionView::TestCase
  include PasswordFieldHelper

  test 'visibility data uses the default timeout and translated labels' do
    data = password_visibility_data

    assert_equal 'visibility', data[:controller]
    assert_equal 5000, data[:visibility_timeout_value]
    assert_equal I18n.t('password_visibility.status.hidden'), data[:visibility_hidden_status_value]
    assert_equal I18n.t('password_visibility.status.visible'), data[:visibility_visible_status_value]
    assert_equal I18n.t('password_visibility.toggle.show'), data[:visibility_show_label_value]
    assert_equal I18n.t('password_visibility.toggle.hide'), data[:visibility_hide_label_value]
  end

  test 'visibility data supports a custom timeout' do
    assert_equal 10_000, password_visibility_data(timeout: 10_000)[:visibility_timeout_value]
  end

  test 'visibility data follows the current locale' do
    I18n.with_locale(:es) do
      data = password_visibility_data

      assert_equal I18n.t('password_visibility.status.hidden'), data[:visibility_hidden_status_value]
      assert_equal I18n.t('password_visibility.status.visible'), data[:visibility_visible_status_value]
      assert_equal I18n.t('password_visibility.toggle.show'), data[:visibility_show_label_value]
      assert_equal I18n.t('password_visibility.toggle.hide'), data[:visibility_hide_label_value]
    end
  end
end
