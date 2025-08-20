# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ProofRejectionReasonsTest < ApplicationSystemTestCase
    setup do
      # Force a clean browser session for each test
      Capybara.reset_sessions!

      setup_fpl_policies

      @admin = create(:admin)
      @user = create(:constituent, hearing_disability: true)
      @application = create(:application, :old_enough_for_new_application, user: @user)
      @application.update!(status: 'needs_information')

      # Attach proofs using the lightweight helper and verify they're attached
      attach_lightweight_proof(@application, :income_proof)
      attach_lightweight_proof(@application, :residency_proof)

      # Verify proofs are actually attached - crucial for button visibility
      unless @application.income_proof.attached? && @application.residency_proof.attached?
        raise "Test setup failed: proofs not attached properly. Income: #{@application.income_proof.attached?}, Residency: #{@application.residency_proof.attached?}"
      end

      # Ensure proof statuses are set correctly for button text to be "Review Proof"
      @application.update!(
        income_proof_status: :not_reviewed,
        residency_proof_status: :not_reviewed
      )

      # Clean up any existing proof reviews for this application to avoid interference
      @application.proof_reviews.destroy_all

      # Don't sign in during setup - let each test handle its own authentication
      # This ensures each test starts with a clean authentication state
    end

    teardown do
      # Ensure any open modals are closed
      begin
        if has_selector?('#proofRejectionModal', visible: true, wait: 1)
          within('#proofRejectionModal') do
            click_button 'Cancel' if has_button?('Cancel', wait: 1)
          end
        end

        if has_selector?('#incomeProofReviewModal', visible: true, wait: 1)
          within('#incomeProofReviewModal') do
            click_button 'Close' if has_button?('Close', wait: 1)
          end
        end

        if has_selector?('#residencyProofReviewModal', visible: true, wait: 1)
          within('#residencyProofReviewModal') do
            click_button 'Close' if has_button?('Close', wait: 1)
          end
        end
      rescue Ferrum::NodeNotFoundError, Ferrum::DeadBrowserError
        # Browser might be in a bad state, reset it
        Capybara.reset_sessions!
      end

      # Always ensure clean session state between tests
      Capybara.reset_sessions!
    end

    test 'admin can see all rejection reasons when rejecting income proof' do
      # Debug basic page loading first
      system_test_sign_in(@admin)

      puts '=== AUTHENTICATION DEBUG AFTER SIGN IN ==='
      puts "Current.user after sign in: #{Current.user&.id}"
      puts "Current path after sign in: #{current_path}"

      # Visit the page and check authentication state using concrete anchors
      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 20

      puts '=== AUTHENTICATION DEBUG AFTER NAVIGATION ==='
      puts "Current.user after navigation: #{Current.user&.id}"
      puts "Current path after navigation: #{current_path}"
      puts "Current URL: #{current_url}"

      # Check if we're redirected to sign-in (would indicate auth failure)
      if current_path == sign_in_path
        puts '❌ REDIRECTED TO SIGN-IN PAGE - AUTHENTICATION LOST'
        flunk 'Authentication was lost after navigation - redirected to sign-in page'
      end

      # Restore Current.user from session if it's missing (common system test issue)
      if Current.user.nil?
        puts '⚠️  Current.user is nil after navigation, attempting to restore from session'
        # Find the session we created during sign-in
        session = Session.joins(:user).where(users: { id: @admin.id }).order(created_at: :desc).first
        if session
          Current.user = session.user
          puts "✅ Restored Current.user from session: #{Current.user.id}"
        else
          puts '❌ No session found for admin user'
          flunk 'No session found for admin user'
        end
      end

      # Check the application is in the database and has the expected state
      @application.reload
      puts '=== APPLICATION DEBUG INFO ==='
      puts "Application ID: #{@application.id}"
      puts "Application Status: #{@application.status}"
      puts "Income proof attached: #{@application.income_proof.attached?}"
      puts "Residency proof attached: #{@application.residency_proof.attached?}"
      puts "Income proof status: #{@application.income_proof_status}"
      puts "User type: #{@application.user.type}"
      puts "Admin authenticated: #{Current.user&.id}"

      # Take screenshot to see what we get
      take_screenshot('basic_page_load_debug')

      # Check what HTML is actually being rendered
      page_html = page.html
      puts '=== PAGE HTML DEBUG ==='
      puts "HTML length: #{page_html.length}"
      puts "Contains <html>: #{page_html.include?('<html>')}"
      puts "Contains <body>: #{page_html.include?('<body>')}"
      puts "Contains 'Application': #{page_html.include?('Application')}"
      puts "Page title from HTML: #{page_html.match(%r{<title>(.*?)</title>})&.captures&.first}"
      puts "Body content preview: #{page_html.match(%r{<body[^>]*>(.*?)</body>}m)&.captures&.first&.[](0, 200)}"

      # DEEP DOM TIMING ANALYSIS
      puts '=== DEEP DOM TIMING ANALYSIS ==='

      # Check document ready state
      ready_state = page.evaluate_script('document.readyState')
      puts "Document ready state: #{ready_state}"

      # Check if Turbo is present and its state
      has_turbo = page.evaluate_script('typeof Turbo !== "undefined"')
      puts "Turbo available: #{has_turbo}"

      if has_turbo
        turbo_loaded = begin
          page.evaluate_script('Turbo.session ? "loaded" : "not loaded"')
        rescue StandardError
          'error'
        end
        puts "Turbo session state: #{turbo_loaded}"
      end

      # Check if DOM has full HTML structure
      full_html = page.evaluate_script('document.documentElement.outerHTML')
      puts "Full HTML from JS length: #{full_html.length}"
      puts "Full HTML contains <html>: #{full_html.include?('<html>')}"
      puts "Full HTML contains <body>: #{full_html.include?('<body>')}"

      # Compare what Capybara sees vs what JavaScript sees
      puts "Capybara HTML length: #{page_html.length}"
      puts "JavaScript HTML length: #{full_html.length}"
      puts "Length difference: #{full_html.length - page_html.length}"

      # Check specific elements via JavaScript
      h1_count_js = page.evaluate_script('document.querySelectorAll("h1").length')
      puts "H1 elements via JavaScript: #{h1_count_js}"

      # Check if specific content exists via JavaScript
      has_application_h1 = page.evaluate_script('Array.from(document.querySelectorAll("h1")).some(h => h.textContent.includes("Application"))')
      puts "Has Application h1 via JavaScript: #{has_application_h1}"

      # Check CSS loading state
      stylesheets_loaded = page.evaluate_script('document.styleSheets.length')
      puts "Stylesheets loaded: #{stylesheets_loaded}"

      # Check for pending requests/network activity
      begin
        performance_entries = page.evaluate_script('performance.getEntriesByType("navigation").length')
        puts "Performance navigation entries: #{performance_entries}"
      rescue StandardError => e
        puts "Performance API error: #{e.message}"
      end

      # Check for any Rails error indicators
      if page_html.include?('We\'re sorry, but something went wrong') ||
         page_html.include?('The page you were looking for doesn\'t exist') ||
         page_html.include?('500 Internal Server Error') ||
         page_html.include?('404 Not Found')
        puts '❌ RAILS ERROR DETECTED IN PAGE'
        puts "Error page HTML: #{page_html[0, 1000]}"
        flunk 'Rails error detected on page'
      end

      # Try to find ANY h1 element first, without specific text
      h1_elements = all('h1', wait: 10)
      puts "Found #{h1_elements.count} h1 elements"
      h1_elements.each_with_index do |h1, i|
        puts "  H1 #{i}: '#{h1.text}'"
      end

      # Check for any elements that might indicate the page loaded
      body_elements = all('body', wait: 2)
      puts "Found #{body_elements.count} body elements"

      div_elements = all('div', wait: 2)
      puts "Found #{div_elements.count} div elements"

      # Only proceed if we have h1 elements
      if h1_elements.empty?
        puts 'No H1 elements found - page may not have loaded properly'
        puts 'Trying to find ANY text content...'
        if page.has_text?('Application', wait: 2)
          puts "Found 'Application' text on page"
        else
          puts "No 'Application' text found"
        end
        flunk 'No H1 elements found on page'
      end

      # Try to find the specific Application h1
      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15

      # Only continue if we can find the attachments section
      assert_selector '#attachments-section', count: 1, wait: 15
      # Open income proof modal via stable helper
      click_review_proof_and_wait('income', timeout: 15)

      within('#incomeProofReviewModal') do
        assert_selector('button', text: 'Reject')
        click_button 'Reject'
      end

      within('#proofRejectionModal') do
        # Wait for proof type field and verify it's set correctly
        assert_selector('#rejection-proof-type', visible: false)
        proof_type_field = find_by_id('rejection-proof-type', visible: false)
        assert_equal 'income', proof_type_field.value

        # Check that all common rejection reason buttons are visible
        assert_selector "button[data-reason-type='addressMismatch']", text: 'Address Mismatch'
        assert_selector "button[data-reason-type='expired']", text: 'Expired Documentation'
        assert_selector "button[data-reason-type='missingName']", text: 'Missing Name'
        assert_selector "button[data-reason-type='wrongDocument']", text: 'Wrong Document Type'

        # Check for income-specific buttons
        assert_selector "button[data-reason-type='missingAmount']", text: 'Missing Amount'
        assert_selector "button[data-reason-type='exceedsThreshold']", text: 'Income Exceeds Threshold'
        assert_selector "button[data-reason-type='outdatedSsAward']", text: 'Outdated SS Award Letter'

        # Close the modal to prevent interference with subsequent tests
        click_button 'Cancel'
      end
    end

    test 'admin can see appropriate rejection reasons when rejecting residency proof' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)
      visit admin_application_path(@application)
      assert_selector '#attachments-section', wait: 30

      # Wait for Turbo navigation to complete (from testing guide)
      wait_for_turbo if respond_to?(:wait_for_turbo)

      # Use count expectations for dynamic content (from testing guide)
      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      # Wait for exactly one residency proof review button using stable selector
      assert_selector 'button[data-modal-id="residencyProofReviewModal"]', count: 1, wait: 15

      # Use find with explicit wait for reliable element interaction
      click_review_proof_and_wait('residency', timeout: 15)

      within('#residencyProofReviewModal') do
        assert_selector('button', text: 'Reject')
        click_button 'Reject'
      end

      within('#proofRejectionModal') do
        # Wait for modal to be initialized and check proof type
        assert_selector('#rejection-proof-type', visible: false, wait: 15)
        proof_type_field = find_by_id('rejection-proof-type', visible: false)
        assert_equal 'residency', proof_type_field.value

        # Check that common rejection reason buttons are visible
        assert_selector "button[data-reason-type='addressMismatch']", text: 'Address Mismatch'
        assert_selector "button[data-reason-type='expired']", text: 'Expired Documentation'
        assert_selector "button[data-reason-type='missingName']", text: 'Missing Name'
        assert_selector "button[data-reason-type='wrongDocument']", text: 'Wrong Document Type'

        # Check that income-specific rejection reason buttons are hidden
        assert_selector "button[data-reason-type='missingAmount']", visible: false
        assert_selector "button[data-reason-type='exceedsThreshold']", visible: false
        assert_selector "button[data-reason-type='outdatedSsAward']", visible: false

        # Close the modal to prevent interference with subsequent tests
        click_button 'Cancel'
      end
    end

    test 'clicking a rejection reason button populates the reason field' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 30

      # Wait for Turbo navigation to complete (from testing guide)
      wait_for_turbo if respond_to?(:wait_for_turbo)

      # Use count expectations for dynamic content (from testing guide)
      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      # Wait for exactly one income proof review button using stable selector
      assert_selector 'button[data-modal-id="incomeProofReviewModal"]', count: 1, wait: 15

      # Use find with explicit wait for reliable element interaction
      click_review_proof_and_wait('income', timeout: 15)

      within('#incomeProofReviewModal') do
        click_button 'Reject'
      end

      # Wait for rejection modal to appear and elements to be ready
      within('#proofRejectionModal') do
        # Wait for the missing name button to be available and click it
        find("button[data-reason-type='missingName']").click

        # Wait for textarea to be populated - use intelligent waiting
        assert_selector("textarea[name='rejection_reason']")

        # Verify the field gets populated with the expected content
        reason_field = find("textarea[name='rejection_reason']")
        assert reason_field.value.present?, 'Rejection reason field should be populated'
        assert_includes reason_field.value, 'does not show your name'

        # Close the modal to prevent interference with subsequent tests
        click_button 'Cancel'
      end
    end

    test 'admin can modify the rejection reason text' do
      # Always sign in fresh for each test
      system_test_sign_in(@admin)
      visit admin_application_path(@application)
      assert_selector '#attachments-section', wait: 20

      # Use count expectations for dynamic content (from testing guide)
      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      # Wait for exactly one income proof review button using stable selector
      assert_selector 'button[data-modal-id="incomeProofReviewModal"]', count: 1, wait: 15

      # Use find with explicit wait for reliable element interaction
      review_button = find('button[data-modal-id="incomeProofReviewModal"]', wait: 10)
      review_button.click

      # Wait for modal to appear using count expectation
      assert_selector '#incomeProofReviewModal', count: 1, wait: 10

      within('#incomeProofReviewModal') do
        click_button 'Reject'
      end

      within('#proofRejectionModal') do
        # Click a rejection reason button and wait for population
        find("button[data-reason-type='missingName']").click

        # Wait for the textarea to be populated after button click
        assert_selector("textarea[name='rejection_reason']")

        # Verify field is populated, then modify it
        reason_field = find("textarea[name='rejection_reason']")
        assert reason_field.value.present?, 'Field should be populated before modification'

        # Clear and modify the reason text
        custom_message = 'Please provide a document with your full legal name clearly visible.'
        reason_field.set(custom_message)

        # Verify the custom message was set correctly
        assert_equal custom_message, reason_field.value

        # Close the modal to prevent interference with subsequent tests
        click_button 'Cancel'
      end
    end
  end
end
