# frozen_string_literal: true

require 'test_helper'

module Admin
  class EquipmentFulfillmentsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin)
      @application = create(:application, :completed, :with_all_proofs,
                            user: create(:constituent, speech_disability: true))
      sign_in_for_integration_test(@admin)
    end

    test 'admin can update equipment bids sent date and audit once' do
      assert_difference -> { Event.where(action: 'equipment_bids_sent', auditable: @application).count }, 1 do
        patch admin_application_equipment_fulfillment_path(@application),
              params: { application: { equipment_bids_sent_at: '2026-01-01' } }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal Date.new(2026, 1, 1), @application.reload.equipment_bids_sent_at.to_date

      event = Event.where(action: 'equipment_bids_sent', auditable: @application).last
      assert_equal @admin, event.user
      assert_equal '2026-01-01', event.metadata['date']
    end

    test 'admin can update equipment po sent date and audit once' do
      assert_difference -> { Event.where(action: 'equipment_po_sent', auditable: @application).count }, 1 do
        patch admin_application_equipment_fulfillment_path(@application),
              params: { application: { equipment_po_sent_at: '2026-02-01' } }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal Date.new(2026, 2, 1), @application.reload.equipment_po_sent_at.to_date

      event = Event.where(action: 'equipment_po_sent', auditable: @application).last
      assert_equal @admin, event.user
      assert_equal '2026-02-01', event.metadata['date']
    end

    test 'blank date fields do not rewrite dates or create audit events' do
      @application.update!(equipment_bids_sent_at: Date.new(2026, 1, 1),
                           equipment_po_sent_at: Date.new(2026, 2, 1))

      assert_no_difference -> { Event.where(action: %w[equipment_bids_sent equipment_po_sent], auditable: @application).count } do
        patch admin_application_equipment_fulfillment_path(@application),
              params: {
                application: {
                  equipment_bids_sent_at: '',
                  equipment_po_sent_at: ''
                }
              }
      end

      assert_redirected_to admin_application_path(@application)
      assert_equal 'Provide a fulfillment date or a tracking number.', flash[:alert]

      @application.reload
      assert_equal Date.new(2026, 1, 1), @application.equipment_bids_sent_at.to_date
      assert_equal Date.new(2026, 2, 1), @application.equipment_po_sent_at.to_date
    end

    test 'dates may be typed in any accepted form, and a tracking number is recorded and audited' do
      patch admin_application_equipment_fulfillment_path(@application),
            params: { application: { equipment_bids_sent_at: '9/9/2026', equipment_po_sent_at: '09102026',
                                     equipment_tracking_number: ' 1Z999AA1 ' } }

      assert_equal 'Equipment fulfillment updated.', flash[:notice]
      @application.reload
      assert_equal Date.new(2026, 9, 9), @application.equipment_bids_sent_at.to_date
      assert_equal Date.new(2026, 9, 10), @application.equipment_po_sent_at.to_date
      assert_equal '1Z999AA1', @application.equipment_tracking_number
      event = Event.find_by!(action: 'equipment_tracking_number_recorded', auditable: @application)
      assert_equal({ 'old' => nil, 'new' => '1Z999AA1' }, event.metadata.dig('changes', 'equipment_tracking_number'))
    end

    test 'saving the form with unchanged dates audits only what changed' do
      @application.update!(equipment_bids_sent_at: Date.new(2026, 1, 1), equipment_po_sent_at: Date.new(2026, 2, 1))

      assert_no_difference -> { Event.where(action: %w[equipment_bids_sent equipment_po_sent], auditable: @application).count } do
        patch admin_application_equipment_fulfillment_path(@application),
              params: { application: { equipment_bids_sent_at: '01/01/2026', equipment_po_sent_at: '02/01/2026',
                                       equipment_tracking_number: 'AAA111' } }
      end
      assert_equal 'AAA111', @application.reload.equipment_tracking_number
    end

    test 'an unreadable date changes nothing' do
      patch admin_application_equipment_fulfillment_path(@application),
            params: { application: { equipment_bids_sent_at: '13/45/2026', equipment_tracking_number: 'AAA111' } }

      assert_equal 'Enter dates as MM/DD/YYYY.', flash[:alert]
      @application.reload
      assert_nil @application.equipment_bids_sent_at
      assert_nil @application.equipment_tracking_number
    end

    test 'voucher applications have no equipment fulfillment' do
      @application.update_columns(fulfillment_type: Application.fulfillment_types[:voucher])

      patch admin_application_equipment_fulfillment_path(@application),
            params: { application: { equipment_tracking_number: 'AAA111' } }

      assert_equal 'Equipment fulfillment applies only to equipment applications.', flash[:alert]
      assert_nil @application.reload.equipment_tracking_number
    end
  end
end
