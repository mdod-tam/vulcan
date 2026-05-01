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
      assert_equal 'Provide at least one fulfillment date.', flash[:alert]

      @application.reload
      assert_equal Date.new(2026, 1, 1), @application.equipment_bids_sent_at.to_date
      assert_equal Date.new(2026, 2, 1), @application.equipment_po_sent_at.to_date
    end
  end
end
