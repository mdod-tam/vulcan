# frozen_string_literal: true

require 'test_helper'

module Admin
  # A vendor converted to another role keeps no vendor-only data, and the conversion saves.
  class UserRoleConversionTest < ActionDispatch::IntegrationTest
    setup do
      sign_in_for_integration_test(create(:admin))
    end

    test 'a vendor becomes a constituent with every vendor-only field reset' do
      vendor = vendor_with_vendor_fields
      vendor.update_column(:date_of_birth, '1980-09-10')

      patch update_role_admin_user_path(vendor), params: { role: 'Constituent' }, as: :json

      assert_response :success
      assert_vendor_fields_reset(User.find(vendor.id), 'Users::Constituent')
    end

    test 'a vendor becomes a trainer with every vendor-only field reset' do
      vendor = vendor_with_vendor_fields

      patch update_role_admin_user_path(vendor), params: { role: 'Trainer' }, as: :json

      assert_response :success
      assert_vendor_fields_reset(User.find(vendor.id), 'Users::Trainer')
    end

    test 'the users list warns before converting a vendor, and only a vendor' do
      vendor = vendor_with_vendor_fields
      trainer = create(:trainer)

      get admin_users_path(q: vendor.email)
      assert_select "[data-controller=role-select][data-role-select-current-role-value='Users::Vendor']" \
                    "[data-role-select-update-role-url-value='#{update_role_admin_user_path(vendor)}']" \
                    '[data-role-select-conversion-warning-value*="may lose their W9 and transaction history"]'

      get admin_users_path(q: trainer.email)
      assert_select "[data-role-select-update-role-url-value='#{update_role_admin_user_path(trainer)}']" \
                    ':not([data-role-select-conversion-warning-value])'
    end

    private

    def vendor_with_vendor_fields
      create(:vendor, :approved, :with_w9, business_name: 'Accessible Phones Co', business_tax_id: '123456789',
                                           website_url: 'https://example.com', terms_accepted_at: 1.day.ago).tap do |vendor|
        vendor.update_columns(w9_status: Users::Vendor.w9_statuses[:approved], w9_rejections_count: 2,
                              last_w9_reminder_sent_at: 1.day.ago)
      end
    end

    def assert_vendor_fields_reset(user, type)
      assert_equal type, user.type
      Users::Vendor::VENDOR_ONLY_ATTRIBUTES.each do |attribute|
        assert_equal User.column_defaults[attribute], user.read_attribute_before_type_cast(attribute), attribute
      end
    end
  end
end
