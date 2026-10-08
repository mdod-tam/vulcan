# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class ProofRejectionReasonsTest < ApplicationSystemTestCase
    setup do
      Capybara.reset_sessions!

      setup_fpl_policies

      @admin = create(:admin)
      @user = create(:constituent, hearing_disability: true)
      @application = create(:application, :old_enough_for_new_application, user: @user)
      @application.update!(status: 'awaiting_proof')

      attach_lightweight_proof(@application, :income_proof)
      attach_lightweight_proof(@application, :residency_proof)

      # Attached proofs determine whether review buttons appear.
      unless @application.income_proof.attached? && @application.residency_proof.attached?
        raise "Test setup failed: proofs not attached properly. Income: #{@application.income_proof.attached?}, Residency: #{@application.residency_proof.attached?}"
      end

      # Unreviewed proofs use the "Review Proof" label.
      @application.update!(
        income_proof_status: :not_reviewed,
        residency_proof_status: :not_reviewed
      )

      # Existing reviews could affect this application's rejection state.
      @application.proof_reviews.destroy_all

      # Each test signs in after the browser session reset.
    end

    teardown do
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
        Capybara.reset_sessions!
      end

      Capybara.reset_sessions!
    end

    test 'admin can see all rejection reasons when rejecting income proof' do
      # Page and authentication diagnostics.
      system_test_sign_in(@admin)

      puts '=== AUTHENTICATION DEBUG AFTER SIGN IN ==='
      puts "Current.user after sign in: #{Current.user&.id}"
      puts "Current path after sign in: #{current_path}"

      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 20

      puts '=== AUTHENTICATION DEBUG AFTER NAVIGATION ==='
      puts "Current.user after navigation: #{Current.user&.id}"
      puts "Current path after navigation: #{current_path}"
      puts "Current URL: #{current_url}"

      if current_path == sign_in_path
        puts '❌ REDIRECTED TO SIGN-IN PAGE - AUTHENTICATION LOST'
        flunk 'Authentication was lost after navigation - redirected to sign-in page'
      end

      # This diagnostic restores Current.user if navigation leaves it unset.
      if Current.user.nil?
        puts '⚠️  Current.user is nil after navigation, attempting to restore from session'
        session = Session.joins(:user).where(users: { id: @admin.id }).order(created_at: :desc).first
        if session
          Current.user = session.user
          puts "✅ Restored Current.user from session: #{Current.user.id}"
        else
          puts '❌ No session found for admin user'
          flunk 'No session found for admin user'
        end
      end

      @application.reload
      puts '=== APPLICATION DEBUG INFO ==='
      puts "Application ID: #{@application.id}"
      puts "Application Status: #{@application.status}"
      puts "Income proof attached: #{@application.income_proof.attached?}"
      puts "Residency proof attached: #{@application.residency_proof.attached?}"
      puts "Income proof status: #{@application.income_proof_status}"
      puts "User type: #{@application.user.type}"
      puts "Admin authenticated: #{Current.user&.id}"

      take_screenshot('basic_page_load_debug')

      page_html = page.html
      puts '=== PAGE HTML DEBUG ==='
      puts "HTML length: #{page_html.length}"
      puts "Contains <html>: #{page_html.include?('<html>')}"
      puts "Contains <body>: #{page_html.include?('<body>')}"
      puts "Contains 'Application': #{page_html.include?('Application')}"
      puts "Page title from HTML: #{page_html.match(%r{<title>(.*?)</title>})&.captures&.first}"
      puts "Body content preview: #{page_html.match(%r{<body[^>]*>(.*?)</body>}m)&.captures&.first&.[](0, 200)}"

      # DOM timing diagnostics.
      puts '=== DEEP DOM TIMING ANALYSIS ==='

      ready_state = page.evaluate_script('document.readyState')
      puts "Document ready state: #{ready_state}"

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

      full_html = page.evaluate_script('document.documentElement.outerHTML')
      puts "Full HTML from JS length: #{full_html.length}"
      puts "Full HTML contains <html>: #{full_html.include?('<html>')}"
      puts "Full HTML contains <body>: #{full_html.include?('<body>')}"

      puts "Capybara HTML length: #{page_html.length}"
      puts "JavaScript HTML length: #{full_html.length}"
      puts "Length difference: #{full_html.length - page_html.length}"

      h1_count_js = page.evaluate_script('document.querySelectorAll("h1").length')
      puts "H1 elements via JavaScript: #{h1_count_js}"

      has_application_h1 = page.evaluate_script('Array.from(document.querySelectorAll("h1")).some(h => h.textContent.includes("Application"))')
      puts "Has Application h1 via JavaScript: #{has_application_h1}"

      stylesheets_loaded = page.evaluate_script('document.styleSheets.length')
      puts "Stylesheets loaded: #{stylesheets_loaded}"

      begin
        performance_entries = page.evaluate_script('performance.getEntriesByType("navigation").length')
        puts "Performance navigation entries: #{performance_entries}"
      rescue StandardError => e
        puts "Performance API error: #{e.message}"
      end

      if page_html.include?('We\'re sorry, but something went wrong') ||
         page_html.include?('The page you were looking for doesn\'t exist') ||
         page_html.include?('500 Internal Server Error') ||
         page_html.include?('404 Not Found')
        puts '❌ RAILS ERROR DETECTED IN PAGE'
        puts "Error page HTML: #{page_html[0, 1000]}"
        flunk 'Rails error detected on page'
      end

      h1_elements = all('h1', wait: 10)
      puts "Found #{h1_elements.count} h1 elements"
      h1_elements.each_with_index do |h1, i|
        puts "  H1 #{i}: '#{h1.text}'"
      end

      body_elements = all('body', wait: 2)
      puts "Found #{body_elements.count} body elements"

      div_elements = all('div', wait: 2)
      puts "Found #{div_elements.count} div elements"

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

      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15

      assert_selector '#attachments-section', count: 1, wait: 15
      click_review_proof_and_wait('income', timeout: 15)

      within('#incomeProofReviewModal') do
        assert_selector('button', text: 'Reject')
        click_button 'Reject'
      end

      within('#proofRejectionModal') do
        assert_selector('#rejection-proof-type', visible: false)
        proof_type_field = find_by_id('rejection-proof-type', visible: false)
        assert_equal 'income', proof_type_field.value

        # Common rejection reasons.
        assert_selector "button[data-reason-code='address_mismatch']", text: 'Address Mismatch'
        assert_selector "button[data-reason-code='expired']", text: 'Expired'
        assert_selector "button[data-reason-code='missing_name']", text: 'Missing Name'
        assert_selector "button[data-reason-code='wrong_document']", text: 'Wrong Document Type'

        # Reasons specific to income proof.
        assert_selector "button[data-reason-code='missing_amount']", text: 'Missing Income Amount'
        assert_selector "button[data-reason-code='exceeds_threshold']", text: 'Income Exceeds Threshold'
        assert_selector "button[data-reason-code='outdated_ss_award']", text: 'Outdated Social Security Award Letter'

        # The current scope already selects the modal.
        click_modal_button('Cancel')
      end
    end

    test 'admin can see appropriate rejection reasons when rejecting residency proof' do
      system_test_sign_in(@admin)

      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 30

      wait_for_turbo if respond_to?(:wait_for_turbo)

      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      assert_selector 'button[data-modal-id="residencyProofReviewModal"]', count: 1, wait: 15

      click_review_proof_and_wait('residency', timeout: 15)

      within('#residencyProofReviewModal') do
        assert_selector('button', text: 'Reject')
        click_button 'Reject'
      end

      within('#proofRejectionModal') do
        assert_selector('#rejection-proof-type', visible: false, wait: 15)
        proof_type_field = find_by_id('rejection-proof-type', visible: false)
        assert_equal 'residency', proof_type_field.value

        assert_selector "button[data-reason-code='address_mismatch']", text: 'Address Mismatch'
        assert_selector "button[data-reason-code='expired']", text: 'Expired'
        assert_selector "button[data-reason-code='missing_name']", text: 'Missing Name'
        assert_selector "button[data-reason-code='wrong_document']", text: 'Wrong Document Type'

        assert_selector "button[data-reason-code='missing_amount']", visible: false
        assert_selector "button[data-reason-code='exceeds_threshold']", visible: false
        assert_selector "button[data-reason-code='outdated_ss_award']", visible: false

        click_modal_button('Cancel')
      end
    end

    test 'clicking a rejection reason button populates the reason field' do
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 30

      wait_for_turbo if respond_to?(:wait_for_turbo)

      assert_selector 'h1', text: /Application.*Details/i, count: 1, wait: 15
      assert_selector '#attachments-section', count: 1, wait: 15

      assert_selector 'button[data-modal-id="incomeProofReviewModal"]', count: 1, wait: 15

      click_review_proof_and_wait('income', timeout: 15)

      within('#incomeProofReviewModal') do
        click_button 'Reject'
      end

      wait_for_modal_open('proofRejectionModal', timeout: 10)

      within('#proofRejectionModal') do
        click_modal_button("button[data-reason-code='missing_name']")

        selected_button = find("button[data-reason-code='missing_name']")
        assert_equal 'true', selected_button['aria-pressed']

        assert_selector("textarea[name='rejection_reason']")

        reason_field = find("textarea[name='rejection_reason']")
        assert reason_field.value.present?, 'Rejection reason field should be populated'
        assert_includes reason_field.value, 'does not show your name'
        assert reason_field[:readonly], 'A predefined reason is read-only'

        assert_selector("[data-rejection-form-target='liveRegion']",
                        text: /Selected rejection reason: Missing Name/i,
                        visible: :all)

        click_modal_button('Cancel')
      end
    end

    test 'selecting Other in the proof rejection modal unlocks custom reason entry' do
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 30

      click_review_proof_and_wait('income', timeout: 15)

      within('#incomeProofReviewModal') do
        click_button 'Reject'
      end

      wait_for_modal_open('proofRejectionModal', timeout: 10)

      within('#proofRejectionModal') do
        click_modal_button("[data-rejection-form-target='generalReasons'] button[aria-label='Enter a custom rejection reason']")

        reason_field = find("textarea[name='rejection_reason']")
        assert_nil reason_field[:readonly], 'Custom reason field should be editable after selecting Other'
        assert_selector "[data-rejection-form-target='languageNotice']", visible: true
        assert_selector "[data-rejection-form-target='codeStatus']", text: /Custom reason/
      end
    end

    test 'a predefined rejection reason cannot be edited; Other is the way to write one' do
      system_test_sign_in(@admin)
      visit_admin_application_with_retry(@application, user: @admin)
      assert_selector '#attachments-section', wait: 20

      click_review_proof_and_wait('income', timeout: 15)
      within('#incomeProofReviewModal') { click_button 'Reject' }
      wait_for_modal_open('proofRejectionModal', timeout: 10)

      within('#proofRejectionModal') do
        click_modal_button("button[data-reason-code='missing_name']")
        reason_field = find("textarea[name='rejection_reason']")
        predefined_text = reason_field.value
        assert predefined_text.present?, 'Field should be populated with the predefined reason'

        reason_field.send_keys(' edited')
        assert_equal predefined_text, reason_field.value

        click_modal_button('Cancel')
      end
    end
  end
end
