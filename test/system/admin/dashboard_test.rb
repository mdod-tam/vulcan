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
      assert_selector 'h1', text: 'Admin Dashboard'

      # Verify status cards section
      assert_selector "section[aria-labelledby='status-cards-heading']"
      assert_selector 'h3', text: /In Progress Applications/i
      assert_selector 'h3', text: /Approved/i

      # Verify common tasks section
      assert_selector "section[aria-labelledby='common-tasks-heading']"
      assert_selector 'h2#common-tasks-heading', text: 'Common Tasks'

      # Verify applications section
      assert_selector "section[aria-labelledby='applications-heading']"

      # Verify charts section appears after applications section
      # Instead of comparing DOM paths, check the order of elements on the page
      assert_selector "section[aria-labelledby='applications-heading'] ~ section[aria-labelledby='charts-heading']"

      # Verify chart headings
      assert_selector 'h3#pipeline-heading', text: 'Application Pipeline'
      assert_selector 'h3#status-breakdown-heading', text: 'Status Breakdown'
    end

    test 'common tasks section shows correct links with counts' do
      visit admin_applications_path

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
      visit admin_applications_path

      # Wait for page to load completely
      assert_selector 'h1', text: 'Admin Dashboard', wait: 15

      # Click on proofs needing review link
      click_on 'Proofs Needing Review'

      # Note: These links use turbo_frame: "applications_list" so URL doesn't change
      # Verify the filter is applied by checking the link is highlighted
      within "section[aria-labelledby='common-tasks-heading']" do
        assert_selector 'a', text: /Proofs Needing Review/, wait: 10
        assert_selector 'a[class*="bg-gray-50"]', text: /Proofs Needing Review/, wait: 10
      end

      # Go back to main page
      visit admin_applications_path

      # Wait for page to load completely
      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      # Click on medical certs to review link
      click_on 'Medical Certs to Review'

      # Verify the link is highlighted (turbo frame navigation doesn't change URL)
      within "section[aria-labelledby='common-tasks-heading']" do
        assert_selector 'a', text: /Medical Certs to Review/, wait: 10
        assert_selector 'a[class*="bg-gray-50"]', text: /Medical Certs to Review/, wait: 10
      end

      # Go back to main page
      visit admin_applications_path

      # Wait for page to load completely
      assert_selector 'h1', text: 'Admin Dashboard', wait: 10

      # Click on training requests link
      click_on 'Training Requests'

      # Verify the link is highlighted (turbo frame navigation doesn't change URL)
      within "section[aria-labelledby='common-tasks-heading']" do
        assert_selector 'a', text: /Training Requests/, wait: 10
        assert_selector 'a[class*="bg-gray-50"]', text: /Training Requests/, wait: 10
      end
    end

    test 'view reports button links to reports page' do
      visit admin_applications_path

      # Click on the View Reports button
      click_on 'View Reports'

      # Verify we're on the reports page
      assert_current_path admin_reports_path

      # Verify the reports page title
      assert_selector 'h1', text: 'System Reports'
    end

    test 'admin action buttons are present and functional' do
      visit admin_applications_path

      # Verify all four admin action buttons are present
      assert_selector 'a', text: 'Edit Policies'
      assert_selector 'a', text: 'Manage Products'
      assert_selector 'a', text: 'Upload Paper Application'
      assert_selector 'a', text: 'View Reports'

      # Test Edit Policies button
      click_on 'Edit Policies'
      assert_current_path admin_policies_path
      visit admin_applications_path

      # Test Manage Products button
      click_on 'Manage Products'
      assert_current_path admin_products_path
      visit admin_applications_path

      # Test Upload Paper Application button
      click_on 'Upload Paper Application'
      assert_current_path new_admin_paper_application_path
      visit admin_applications_path

      # Test View Reports button (already tested in previous test, but included for completeness)
      click_on 'View Reports'
      assert_current_path admin_reports_path
    end

    test 'admin can access core administrative functions' do
      visit admin_applications_path

      # Test that users can access key administrative functions
      assert_selector "a[aria-label*='paper application']" # Can upload papers
      assert_selector "a[aria-label*='policies']"          # Can edit policies
      assert_selector "a[aria-label*='products']"          # Can manage products
      assert_selector "a[aria-label*='reports']"           # Can view reports

      # Test accessibility patterns for primary actions
      page.all('a[aria-label]').each do |button|
        assert button['aria-label'].present?, "Button missing aria-label: #{button.text}"
      end
    end
  end
end
