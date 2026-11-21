# frozen_string_literal: true

require 'test_helper'

module Equipment
  class ShippingPrivacyTest < ActiveSupport::TestCase
    test 'shipping snapshots decrypt operationally but raw storage parameters and cross-model nested audits protect them' do
      admin = create(:admin)
      application = create(:application, :approved, :with_all_proofs, fulfillment_type: :equipment,
                                                                      shipping_care_of: 'Private Guardian', shipping_address_1: '744 Secret Road', shipping_state: 'MD')
      item = create(:equipment_item, application:, shipping_care_of: application.shipping_care_of,
                                     shipping_address_1: application.shipping_address_1, shipping_state: application.shipping_state)
      assert_equal '744 Secret Road', item.reload.shipping_address_1
      raw = EquipmentItem.connection.select_value("SELECT shipping_address_1 FROM equipment_items WHERE id = #{item.id}")
      assert_not_includes raw, '744 Secret Road'
      payload = EquipmentShipping::FIELDS.index_with { 'private-value' }.merge('disability_setup_group' => 'deafblind')
      [application, item, item.purchase_order].each do |record|
        Mutation.audit!(record, actor: admin, action: 'equipment_profile_privacy_test', changes: { nested: [payload] })
        event = Event.where(auditable: record, action: 'equipment_profile_privacy_test').order(:id).last
        raw_metadata = Event.connection.select_value("SELECT metadata::text FROM events WHERE id = #{event.id}")
        assert_not_includes raw_metadata, 'private-value'
        assert_not_includes raw_metadata, 'deafblind'
        assert_includes raw_metadata, '[withheld]'
      end
      filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter('nested' => payload)
      EquipmentShipping::FIELDS.each { |field| assert_equal '[FILTERED]', filtered['nested'][field] }
    end
  end
end
