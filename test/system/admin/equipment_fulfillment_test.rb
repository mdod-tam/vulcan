# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class EquipmentFulfillmentTest < ApplicationSystemTestCase
    test 'staff record bid and PO dates and a tracking number on the application page' do
      application = create(:application, :completed, :with_all_proofs, status: :approved,
                                                                       user: create(:constituent, speech_disability: true))
      create(:evaluation, :completed, application: application, constituent: application.user)
      system_test_sign_in(create(:admin))
      install_stimulus_error_reporting

      visit admin_application_path(application)
      within('section[aria-labelledby=equipment-fulfillment-title]') do
        fill_in 'Date bids sent', with: '9/9/2026'
        fill_in 'Date PO sent', with: '09102026'
        fill_in 'Tracking number', with: '1Z999AA1'
        click_button 'Save equipment fulfillment'
      end

      assert_text 'Equipment fulfillment updated.'
      within('section[aria-labelledby=equipment-fulfillment-title]') do
        assert_text 'PO Sent on 09/10/2026'
        assert_field 'Date bids sent', with: '09/09/2026'
        assert_field 'Tracking number', with: '1Z999AA1'
      end
      take_screenshot('admin-equipment-fulfillment-saved', html: true, full: true)
    end
  end
end
