# frozen_string_literal: true

require 'test_helper'

module Admin
  class FeatureFlagsControllerTest < ActionController::TestCase
    setup do
      @admin = create(:admin)
      sign_in_as @admin
      @feature_flag = create(:feature_flag, name: 'test_feature', enabled: true)
    end

    test 'index displays all feature flags' do
      flag2 = create(:feature_flag, name: 'another_feature', enabled: false)
      get :index
      assert_response :success
      assert_includes assigns(:feature_flags), @feature_flag
      assert_includes assigns(:feature_flags), flag2
    end

    test 'index requires authentication' do
      sign_out
      get :index
      assert_redirected_to sign_in_path
    end

    test 'index requires admin role' do
      user = create(:user)
      sign_in_as user
      get :index
      assert_redirected_to root_url
    end

    test 'update toggles feature flag enabled status' do
      assert @feature_flag.enabled?
      patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false } }
      @feature_flag.reload
      assert_not @feature_flag.enabled?
    end

    test 'update creates audit event' do
      assert_difference('Event.count', 1) do
        patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false } }
      end
      event = Event.last
      assert_equal 'feature_flag_toggled', event.action
      assert_equal @admin, event.user
      assert_equal @feature_flag, event.auditable
    end

    test 'update audit event includes metadata' do
      patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false } }
      event = Event.last
      metadata = event.metadata
      assert_equal 'test_feature', metadata['flag_name']
      assert_equal true, metadata['old_value']
      assert_equal false, metadata['new_value']
      assert_equal @admin.id, metadata['admin_id']
      assert_equal @admin.full_name, metadata['admin_name']
    end

    test 'update redirects to index with success notice' do
      patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false } }
      assert_redirected_to admin_feature_flags_path
      assert_equal 'Feature flag updated successfully', flash[:notice]
    end

    test 'update enables disabled feature flag' do
      disabled_flag = create(:feature_flag, name: 'disabled_feature', enabled: false)
      assert_not disabled_flag.enabled?
      patch :update, params: { id: disabled_flag.id, feature_flag: { enabled: true } }
      disabled_flag.reload
      assert disabled_flag.enabled?
    end

    test 'update requires authentication' do
      sign_out
      patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false } }
      assert_redirected_to sign_in_path
    end

    test 'update requires admin role' do
      user = create(:user)
      sign_in_as user
      patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false } }
      assert_redirected_to root_url
    end

    test 'update with invalid feature flag id raises error' do
      assert_raises(ActiveRecord::RecordNotFound) do
        patch :update, params: { id: 'invalid_id', feature_flag: { enabled: false } }
      end
    end

    test 'update only permits enabled parameter' do
      patch :update, params: { id: @feature_flag.id, feature_flag: { enabled: false, name: 'hacked' } }
      @feature_flag.reload
      assert_equal 'test_feature', @feature_flag.name
    end
  end
end
