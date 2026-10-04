# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DashboardTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)

      @draft_app = create(:application, :draft)
      @in_progress_app = create(:application, :in_progress)
      @approved_app = create(:application, :approved)

      @app_with_pending_proof = create(:application,
                                       status: 'in_progress',
                                       income_proof_status: 'not_reviewed',
                                       residency_proof_status: 'not_reviewed')

      @app_with_medical_cert = create(:application, :in_progress)
      @app_with_medical_cert.update!(medical_certification_status: :received)

      system_test_sign_in(@admin)
    end

    test 'applications page loads the status chart frame' do
      visit admin_applications_path

      assert_selector 'h1', text: 'Applications'

      assert_selector "section[aria-labelledby='applications-heading']"

      scroll_to find('turbo-frame#charts_section')
      assert_selector "turbo-frame#charts_section section[aria-labelledby='charts-heading']"

      assert_selector 'h3#status-breakdown-heading', text: /Application Status Snapshot/
    end

    test 'common tasks links display numeric counts' do
      visit admin_dashboard_path

      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      assert_selector "section[aria-labelledby='common-tasks-heading']", wait: 10

      within "section[aria-labelledby='common-tasks-heading']" do
        assert_selector 'a', text: /Proofs Needing Review \(\d+\)/, wait: 10

        assert_selector 'a', text: /Medical Certs to Review \(\d+\)/, wait: 10

        assert_selector 'a', text: /Training Requests \(\d+\)/, wait: 10
      end
    end

    test 'common task links open the matching application filters' do
      visit admin_dashboard_path

      assert_selector 'h1', text: 'Admin Dashboard', wait: 15

      click_on 'Proofs Needing Review'

      assert_current_path admin_applications_path(filter: 'proofs_needing_review')
      assert_selector 'h1', text: 'Applications', wait: 10

      visit admin_dashboard_path

      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      click_on 'Medical Certs to Review'

      assert_current_path admin_applications_path(filter: 'medical_certs_to_review')
      assert_selector 'h1', text: 'Applications', wait: 10

      visit admin_dashboard_path

      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      click_on 'Training Requests'

      assert_current_path admin_applications_path(filter: 'training_requests')
      assert_selector 'h1', text: 'Applications', wait: 10
    end

    test 'view reports button links to reports page' do
      visit admin_dashboard_path

      click_on 'Reports'

      assert_current_path admin_reports_path

      assert_selector 'h1', text: 'System Reports'
    end

    test 'admin action links are present and selected links navigate' do
      visit admin_dashboard_path

      assert_selector 'a', text: 'Apply for Constituent'
      assert_selector 'a', text: 'Applications'
      assert_selector 'a', text: 'Reports'
      assert_selector 'a', text: 'Edit Policies'
      assert_selector 'a', text: 'Manage Products'

      click_on 'Edit Policies'
      assert_current_path admin_policies_path
      visit admin_dashboard_path

      click_on 'Manage Products'
      assert_current_path admin_products_path
      visit admin_dashboard_path

      click_on 'Apply for Constituent'
      assert_current_path new_admin_paper_application_path
      visit admin_dashboard_path

      click_on 'Reports'
      assert_current_path admin_reports_path
    end

    test 'immediate apply for constituent click navigates and checks selected console errors' do
      console_errors = []
      if page.driver.respond_to?(:browser) && page.driver.browser.respond_to?(:on)
        page.driver.browser.on(:console) do |message|
          next unless message.respond_to?(:type) && message.type == :error

          console_errors << message.text
        end
      end

      visit admin_dashboard_path
      click_on 'Apply for Constituent'

      assert_current_path new_admin_paper_application_path
      assert_selector 'h1', text: 'Apply for Constituent'
      assert_empty console_errors.grep(/RangeError|Maximum call stack size exceeded|getComputedStyle/i)
    end

    test 'admin dashboard action links have accessible labels' do
      visit admin_dashboard_path

      assert_selector "a[aria-label*='constituent']"
      assert_selector "a[aria-label*='applications']"
      assert_selector "a[aria-label*='policies']"
      assert_selector "a[aria-label*='products']"
      assert_selector "a[aria-label*='reports']"

      page.all('a[aria-label]').to_a.each do |button|
        assert button['aria-label'].present?, "Button missing aria-label: #{button.text}"
      end
    end
  end
end
