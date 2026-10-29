# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class SessionExpiryModalTest < ApplicationSystemTestCase
    test 'expired session preserves an admin modal draft and focuses its localized notice' do
      admin = create(:admin, locale: :es)
      application = create(:application, :in_progress_with_pending_proofs)
      sign_in_with_totp(admin)
      page.current_window.resize_to(1200, 900)
      visit admin_application_path(application)
      first('[data-modal-id="residencyProofReviewModal"]').click
      within('#residencyProofReviewModal') { click_button 'Reject' }
      assert_selector '#proofRejectionModal[open]'
      draft = 'Unfinished residency rejection explanation'
      within('#proofRejectionModal') do
        click_button 'Other', exact: true
        fill_in 'Reason for Rejection', with: draft
      end

      admin.sessions.order(:id).last.update!(last_active_at: 31.minutes.ago)
      page.execute_script(<<~JS)
        window.originalSessionClock = Date.now;
        Date.now = () => window.originalSessionClock() + 31 * 60 * 1000;
        window.sessionActivityModalSubmissions = 0;
        document.querySelector('#proofRejectionModal form').addEventListener('turbo:submit-start', () => {
          window.sessionActivityModalSubmissions += 1;
        });
      JS
      within('#proofRejectionModal') do
        click_button 'Submit', exact: true
        assert_selector '[data-session-activity-expired-notice][role="alert"]', text: I18n.t('sessions.activity.messages.expired', locale: :es)
        assert_field 'Reason for Rejection', with: draft
        fill_in 'Reason for Rejection', with: "#{draft} to copy"
        click_button 'Submit', exact: true
        assert_field 'Reason for Rejection', with: "#{draft} to copy"
        assert_selector '[data-session-activity-expired-notice]', count: 1
      end
      assert_current_path admin_application_path(application)
      assert_selector '#proofRejectionModal[open]'
      assert page.evaluate_script('document.activeElement.matches("#proofRejectionModal [data-session-activity-expired-notice]")')
      assert_equal 0, page.evaluate_script('window.sessionActivityModalSubmissions')
      assert_equal 'not_reviewed', application.reload.residency_proof_status
      assert_empty application.proof_reviews
      colors = page.evaluate_script(<<~JS)
        (() => {
          const style = getComputedStyle(document.querySelector('#proofRejectionModal textarea'));
          return { text: style.color, background: style.backgroundColor };
        })()
      JS
      assert_not_equal colors.fetch('background'), colors.fetch('text'), 'The preserved draft must remain readable'
      take_screenshot('admin-modal-session-expired', html: true, full: true)
      within('#proofRejectionModal') { assert_field 'Reason for Rejection', with: "#{draft} to copy" }
    ensure
      page.execute_script('if (window.originalSessionClock) Date.now = window.originalSessionClock') if page.has_selector?('body', wait: 0)
    end

    test 'expired session stops a Turbo frame edit before it can discard the draft' do
      admin = create(:admin)
      application = create(:application, :in_progress)
      sign_in_with_totp(admin)
      visit admin_user_path(application.user)
      find("button[data-application-id='#{application.id}'][data-action='click->application-modal#open']").click
      within('#application-modal') { click_button 'Edit', exact: true }
      frame_form = '#application-edit-modal-content form'
      assert_selector "#{frame_form}[data-turbo-frame='application-edit-modal-content']"
      within('#application-edit-modal') { fill_in 'application_certifying_professional_name', with: 'Unsaved provider correction' }
      expire_and_count_submissions(admin, frame_form)

      within('#application-edit-modal') do
        click_button 'Update Application'
        assert_selector '[data-session-activity-expired-notice]', text: I18n.t('sessions.activity.messages.expired')
        assert_field 'application_certifying_professional_name', with: 'Unsaved provider correction'
      end
      assert_current_path admin_user_path(application.user)
      assert_equal 0, page.evaluate_script('window.expiredFormSubmissions')
      assert page.evaluate_script('document.activeElement.matches("#application-edit-modal [data-session-activity-expired-notice]")')
      assert_not_equal 'Unsaved provider correction', application.reload.certifying_professional_name
      take_screenshot('admin-frame-edit-session-expired', html: true, full: true)
    ensure
      page.execute_script('if (window.originalSessionClock) Date.now = window.originalSessionClock') if page.has_selector?('body', wait: 0)
    end

    test 'expired session stops a W9 review and retains the rejection explanation' do
      admin = create(:admin)
      vendor = create(:vendor, :with_w9)
      sign_in_with_totp(admin)
      visit new_admin_vendor_w9_review_path(vendor)
      click_button 'Reject', exact: true
      choose 'Address Mismatch'
      fill_in 'Detailed Explanation', with: 'Unsaved W9 review explanation'
      expire_and_count_submissions(admin, '#review-form')
      click_button 'Confirm Reject'

      assert_selector '[data-session-activity-target="notice"]', text: I18n.t('sessions.activity.messages.expired')
      assert_field 'Detailed Explanation', with: 'Unsaved W9 review explanation'
      assert_current_path new_admin_vendor_w9_review_path(vendor)
      assert_equal 0, page.evaluate_script('window.expiredFormSubmissions')
      assert_empty vendor.reload.w9_reviews
      assert page.evaluate_script('document.activeElement.matches("[data-session-activity-target=notice]")')
      take_screenshot('admin-w9-review-session-expired', html: true, full: true)
    ensure
      page.execute_script('if (window.originalSessionClock) Date.now = window.originalSessionClock') if page.has_selector?('body', wait: 0)
    end

    private

    def sign_in_with_totp(admin)
      credential = admin.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Browser authenticator')
      visit sign_in_path
      within('form[action="/sign_in"]') do
        fill_in 'contact-input', with: admin.email
        fill_in 'password-input', with: 'password1234'
        click_button 'Sign In'
      end
      assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
      within("form[action='#{process_verification_two_factor_authentication_path(type: 'totp')}']") do
        fill_in 'code', with: ROTP::TOTP.new(credential.secret).now
        find('[type="submit"]').click
      end
      assert_current_path admin_dashboard_path
    end

    def expire_and_count_submissions(admin, selector)
      admin.sessions.order(:id).last.update!(last_active_at: 31.minutes.ago)
      page.execute_script(<<~JS, selector)
        window.originalSessionClock = Date.now;
        Date.now = () => window.originalSessionClock() + 31 * 60 * 1000;
        window.expiredFormSubmissions = 0;
        document.querySelector(arguments[0]).addEventListener('turbo:submit-start', () => {
          window.expiredFormSubmissions += 1;
        });
      JS
    end
  end
end
