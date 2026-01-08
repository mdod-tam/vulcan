# frozen_string_literal: true

require 'test_helper'

class FeatureFlagTest < ActiveSupport::TestCase
  setup do
    @feature_flag = create(:feature_flag, name: 'test_feature', enabled: true)
  end

  test 'validates presence of name' do
    flag = FeatureFlag.new(enabled: true)
    assert_not flag.valid?
    assert flag.errors[:name].present?
  end

  test 'validates uniqueness of name' do
    duplicate = FeatureFlag.new(name: @feature_flag.name, enabled: false)
    assert_not duplicate.valid?
    assert duplicate.errors[:name].present?
  end

  test 'enabled? returns true when flag is enabled' do
    assert FeatureFlag.enabled?('test_feature')
  end

  test 'enabled? returns false when flag is disabled' do
    disabled_flag = create(:feature_flag, name: 'disabled_feature', enabled: false)
    assert_not FeatureFlag.enabled?('disabled_feature')
  end

  test 'enabled? returns default value when flag does not exist' do
    assert_not FeatureFlag.enabled?('nonexistent_feature')
    assert FeatureFlag.enabled?('nonexistent_feature', default: true)
  end

  test 'enabled? handles symbol feature names' do
    assert FeatureFlag.enabled?(:test_feature)
  end

  test 'enabled? rescues errors and returns default' do
    FeatureFlag.stubs(:find_by).raises(StandardError.new('Database error'))
    assert_not FeatureFlag.enabled?('any_feature')
    assert FeatureFlag.enabled?('any_feature', default: true)
  end

  test 'enable! creates flag if it does not exist' do
    assert_not FeatureFlag.exists?(name: 'new_feature')
    FeatureFlag.enable!('new_feature')
    assert FeatureFlag.exists?(name: 'new_feature')
    assert FeatureFlag.enabled?('new_feature')
  end

  test 'enable! updates existing flag to enabled' do
    disabled_flag = create(:feature_flag, name: 'to_enable', enabled: false)
    assert_not disabled_flag.enabled?
    FeatureFlag.enable!('to_enable')
    assert FeatureFlag.enabled?('to_enable')
  end

  test 'disable! creates flag if it does not exist' do
    assert_not FeatureFlag.exists?(name: 'new_disabled_feature')
    FeatureFlag.disable!('new_disabled_feature')
    assert FeatureFlag.exists?(name: 'new_disabled_feature')
    assert_not FeatureFlag.enabled?('new_disabled_feature')
  end

  test 'disable! updates existing flag to disabled' do
    enabled_flag = create(:feature_flag, name: 'to_disable', enabled: true)
    assert enabled_flag.enabled?
    FeatureFlag.disable!('to_disable')
    assert_not FeatureFlag.enabled?('to_disable')
  end
end
