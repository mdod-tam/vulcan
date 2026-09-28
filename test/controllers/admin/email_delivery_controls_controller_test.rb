# frozen_string_literal: true

require 'test_helper'

module Admin
  class EmailDeliveryControlsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'turning a category off cancels its pending mail and leaves other categories on' do
      patch admin_email_delivery_control_path, headers: default_headers,
                                               params: { control: 'email.category.proof', enabled: false,
                                                         expected_enabled: true, operation_id: 'op-1' }

      assert_redirected_to admin_email_templates_path(anchor: 'email-delivery')
      assert_match 'Proof is now off', flash[:notice]
      assert_match 'canceled', flash[:notice]
      proof = FeatureFlag.find_by!(name: 'email.category.proof')
      assert_not proof.enabled
      assert_equal 1, proof.delivery_generation
      assert FeatureFlag.find_by!(name: 'email.category.voucher').enabled
    end

    test 'turning the master control off keeps each category setting' do
      patch admin_email_delivery_control_path, headers: default_headers,
                                               params: { control: 'email.global', enabled: false, operation_id: 'op-1' }

      assert_not FeatureFlag.find_by!(name: 'email.global').enabled
      assert FeatureFlag.where(name: EmailDelivery::CONTROL_NAMES - ['email.global']).all?(&:enabled)
    end

    test 'an unknown control name is refused without changes' do
      assert_no_difference('Event.count') do
        patch admin_email_delivery_control_path, headers: default_headers,
                                                 params: { control: 'vouchers_enabled', enabled: true, operation_id: 'op-1' }
      end

      assert_match 'Unknown email control', flash[:alert]
    end

    test 'a non-admin cannot change email controls' do
      sign_out
      sign_in_for_integration_test(create(:constituent))

      patch admin_email_delivery_control_path, headers: default_headers,
                                               params: { control: 'email.global', enabled: false, operation_id: 'op-1' }

      assert FeatureFlag.find_by!(name: 'email.global').enabled
    end
  end
end
