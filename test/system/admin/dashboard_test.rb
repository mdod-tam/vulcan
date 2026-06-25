# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class DashboardTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)

      # Create some applications with different statuses
      @draft_app = create(:application, :draft)
      @in_progress_app = create(:application, :in_progress)
      @approved_app = create(:application, :approved)

      # Create applications with proofs needing review
      @app_with_pending_proof = create(:application,
                                       status: 'in_progress',
                                       income_proof_status: 'not_reviewed',
                                       residency_proof_status: 'not_reviewed')

      # Create application with medical certification received
      @app_with_medical_cert = create(:application, :in_progress)
      @app_with_medical_cert.update!(medical_certification_status: :received)

      # Skip training request for now since the columns don't exist in the database
      # @app_with_training = create(:application, :in_progress)
      # @app_with_training.user.update!(training_requested: true, training_completed: false)

      # Sign in as admin using system test method for better timing
      system_test_sign_in(@admin)
    end

    test 'dashboard displays correct layout with charts below applications' do
      visit admin_applications_path

      # Verify page title
      assert_selector 'h1', text: 'Applications'

      # Verify applications section
      assert_selector "section[aria-labelledby='applications-heading']"

      # Verify charts section appears in the lazy-loaded frame below applications
      scroll_to find('turbo-frame#charts_section')
      assert_selector "turbo-frame#charts_section section[aria-labelledby='charts-heading']"

      # Verify chart heading
      assert_selector 'h3#status-breakdown-heading', text: /Application Status Snapshot/
    end

    test 'common tasks section shows correct links with counts' do
      visit admin_dashboard_path

      # Wait for page to fully load and authenticate
      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      # Wait for common tasks section to be present before making assertions
      assert_selector "section[aria-labelledby='common-tasks-heading']", wait: 10

      within "section[aria-labelledby='common-tasks-heading']" do
        # Check for proofs needing review link with explicit wait
        assert_selector 'a', text: /Proofs Needing Review \(\d+\)/, wait: 10

        # Check for medical certs to review link with explicit wait
        assert_selector 'a', text: /Medical Certs to Review \(\d+\)/, wait: 10

        # Check for training requests link with explicit wait
        assert_selector 'a', text: /Training Requests \(\d+\)/, wait: 10
      end
    end

    test 'clicking on common tasks links filters applications correctly' do
      visit admin_dashboard_path

      # Wait for page to load completely
      assert_selector 'h1', text: 'Admin Dashboard', wait: 15

      # Click on proofs needing review link
      click_on 'Proofs Needing Review'

      assert_current_path admin_applications_path(filter: 'proofs_needing_review')
      assert_selector 'h1', text: 'Applications', wait: 10

      # Go back to main page
      visit admin_dashboard_path

      # Wait for page to load completely
      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      # Click on medical certs to review link
      click_on 'Medical Certs to Review'

      assert_current_path admin_applications_path(filter: 'medical_certs_to_review')
      assert_selector 'h1', text: 'Applications', wait: 10

      # Go back to main page
      visit admin_dashboard_path

      # Wait for page to load completely
      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      # Click on training requests link
      click_on 'Training Requests'

      assert_current_path admin_applications_path(filter: 'training_requests')
      assert_selector 'h1', text: 'Applications', wait: 10
    end

    test 'view reports button links to reports page' do
      visit admin_dashboard_path

      # Click on the Reports button
      click_on 'Reports'

      # Verify we're on the reports page
      assert_current_path admin_reports_path

      # Verify the reports page title
      assert_selector 'h1', text: 'System Reports'
    end

    test 'admin action buttons are present and functional' do
      visit admin_dashboard_path

      # Verify key admin action buttons are present
      assert_selector 'a', text: 'Apply for Constituent'
      assert_selector 'a', text: 'Applications'
      assert_selector 'a', text: 'Reports'
      assert_selector 'a', text: 'Edit Policies'
      assert_selector 'a', text: 'Manage Products'

      # Test Edit Policies button
      click_on 'Edit Policies'
      assert_current_path admin_policies_path
      visit admin_dashboard_path

      # Test Manage Products button
      click_on 'Manage Products'
      assert_current_path admin_products_path
      visit admin_dashboard_path

      # Test Apply for Constituent button
      click_on 'Apply for Constituent'
      assert_current_path new_admin_paper_application_path
      visit admin_dashboard_path

      # Test Reports button (already tested in previous test, but included for completeness)
      click_on 'Reports'
      assert_current_path admin_reports_path
    end

    test 'immediate apply for constituent click navigates without blocking javascript errors' do
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

    test 'admin can access core administrative functions' do
      visit admin_dashboard_path

      # Test that users can access key administrative functions
      assert_selector "a[aria-label*='constituent']"  # Can create applications
      assert_selector "a[aria-label*='applications']" # Can view applications
      assert_selector "a[aria-label*='policies']"     # Can edit policies
      assert_selector "a[aria-label*='products']"     # Can manage products
      assert_selector "a[aria-label*='reports']"      # Can view reports

      # Test accessibility patterns for primary actions
      page.all('a[aria-label]').to_a.each do |button|
        assert button['aria-label'].present?, "Button missing aria-label: #{button.text}"
      end
    end
  end
end
