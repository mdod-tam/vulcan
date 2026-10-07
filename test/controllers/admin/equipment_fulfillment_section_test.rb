# frozen_string_literal: true

require 'test_helper'

module Admin
  # Equipment fulfillment lives on the admin application page, not the evaluation page.
  class EquipmentFulfillmentSectionTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      @application = create(:application, :completed, :with_all_proofs, status: :approved,
                                                                        user: create(:constituent, speech_disability: true))
      assert @application.equipment_fulfillment?, 'precondition: an equipment application'
    end

    test 'after a completed evaluation, the application page offers the dates and tracking number' do
      evaluation = create(:evaluation, :completed, application: @application, constituent: @application.user)
      @application.mark_equipment_bids_sent!(date: '9/9/2026', actor: @admin)
      @application.record_equipment_tracking_number!(number: '1Z999AA1', actor: @admin)

      get admin_application_path(@application)

      assert_select 'section[aria-labelledby=equipment-fulfillment-title]' do
        assert_select 'h2', 'Equipment Fulfillment'
        assert_select "form[action='#{admin_application_equipment_fulfillment_path(@application)}']"
        assert_select 'input[name="application[equipment_bids_sent_at]"][value="09/09/2026"][inputmode=numeric]'
        assert_select 'input[name="application[equipment_po_sent_at]"]:not([value])'
        assert_select 'input[name="application[equipment_tracking_number]"][value="1Z999AA1"]'
        assert_select 'span', text: %r{Sent for bid on 09/09/2026}
      end

      sign_in_for_integration_test(create(:admin))
      get evaluators_evaluation_path(evaluation)
      assert_select "form[action='#{admin_application_equipment_fulfillment_path(@application)}']", count: 0
    end

    test 'before the evaluation is completed, the section explains when it opens' do
      get admin_application_path(@application)

      assert_select 'section[aria-labelledby=equipment-fulfillment-title]', text: /once the evaluation is completed/
      assert_select "form[action='#{admin_application_equipment_fulfillment_path(@application)}']", count: 0
    end

    test 'voucher applications have no equipment fulfillment section' do
      @application.update_columns(fulfillment_type: Application.fulfillment_types[:voucher])

      get admin_application_path(@application)

      assert_select 'section[aria-labelledby=equipment-fulfillment-title]', count: 0
    end
  end
end
