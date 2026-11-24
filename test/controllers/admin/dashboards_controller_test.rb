# frozen_string_literal: true

require 'test_helper'

module Admin
  class DashboardsControllerTest < ActionDispatch::IntegrationTest
    def setup
      @admin_david = create(:admin, email: 'david@example.com', first_name: 'David')
    end

    def test_should_get_index
      sign_in_as(@admin_david, bypass_mfa_enrollment: true)
      get admin_root_path
      assert_response :success
      assert_select 'a.skip-link[href="#dashboard-content"]'
      assert_select 'h1', count: 1, text: 'Admin Dashboard'
      assert_select '#dashboard-content > div > div:first-child ul li', count: 5
      assert_select 'li', text: /awaiting proofs from constituents/, count: 1
      assert_select 'li', text: /awaiting certifications from providers/, count: 1
      assert_select 'li', text: /needing cert request/, count: 1
      assert_select 'li', text: /with signed certifications to review/, count: 0
      %w[awaiting_proofs proofs_needing_review cert_requests_needed certifications_awaiting_provider certifications_needing_review].each do |filter|
        assert_select '#dashboard-content li a[href=?]', admin_applications_path(view: 'review', status: 'active', filter: filter), count: 1
      end
      assert_select '#dashboard-content li a[href=?]', admin_applications_path(view: 'all', filter: 'awaiting_training'), count: 1
      %w[awaiting_evaluation getting_bids ready_to_send_po awaiting_shipment].each do |stage|
        assert_select '#dashboard-content li a[href=?]', admin_applications_path(view: 'pipeline', group: 'equipment', stage: stage), count: 1
      end
      assert_select 'nav[aria-label="Equipment and program tools"]', count: 0
      assert_select 'section[aria-labelledby="equipment-tools-heading"]' do
        assert_select 'a[href=?]', admin_equipment_index_path, count: 1
        assert_select 'a[href=?]', admin_icanconnect_filing_prep_path, count: 1
      end
      configuration = css_select('section[aria-labelledby="configuration-tools-heading"]').sole
      assert_equal admin_policies_path, configuration.css('a').first["href"]
      assert_select 'a[href=?]', admin_products_path, count: 1, text: /Manage Products/
    end
  end
end
