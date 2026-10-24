# frozen_string_literal: true

require 'application_system_test_case'

module Admin
  class SessionDocumentAccessTest < ApplicationSystemTestCase
    setup do
      @admin = create(:admin)
      credential = @admin.totp_credentials.create!(secret: ROTP::Base32.random_base32, nickname: 'Browser authenticator')
      visit sign_in_path
      within('form[action="/sign_in"]') do
        fill_in 'contact-input', with: @admin.email
        fill_in 'password-input', with: 'password1234'
        click_button 'Sign In'
      end
      assert_current_path verify_method_two_factor_authentication_path(type: 'totp')
      within("form[action='#{process_verification_two_factor_authentication_path(type: 'totp')}']") do
        fill_in 'code', with: ROTP::TOTP.new(credential.secret).now
        click_button I18n.t('two_factor_verification.common.submit')
      end
      assert_current_path admin_dashboard_path
    end

    test 'typing on a long paper form refreshes idle time without losing entries' do
      visit new_admin_paper_application_path
      click_button 'Create New Applicant'
      field = find('input[name="constituent[first_name]"]')
      field.set('Unfinished')
      session_record = @admin.sessions.order(:id).last
      absolute_expiry = session_record.expires_at
      session_record.update!(last_active_at: 29.minutes.ago)
      old_activity = session_record.last_active_at

      # Advance only the browser's deadline clock; the server has a genuinely old activity row.
      page.execute_script(<<~JS)
        window.originalSessionClock = Date.now;
        Date.now = () => window.originalSessionClock() + 29 * 60 * 1000;
      JS
      assert_selector '[data-session-activity-target="notice"]', visible: true
      assert_text 'Your session expires in 1 minute'
      assert_equal old_activity, session_record.reload.last_active_at
      assert_equal 'Unfinished', field.value
      take_screenshot('paper-form-session-warning', html: true, full: true)

      field.send_keys(:end, ' entry')
      wait_until { session_record.reload.last_active_at > old_activity }
      assert_current_path new_admin_paper_application_path, ignore_query: true
      assert_equal absolute_expiry, session_record.reload.expires_at
      assert_equal 'Unfinished entry', field.value
      assert_no_selector '[data-session-activity-target="notice"]', visible: true
      take_screenshot('paper-form-session-renewed', html: true, full: true)
    ensure
      page.execute_script('if (window.originalSessionClock) Date.now = window.originalSessionClock') if page.has_selector?('body', wait: 0)
    end

    test 'proof review and certification links work on a page left open beyond download URL expiry' do
      ensure_system_audit_actor!
      application = create(:application, :in_progress)
      application.income_proof.attach(io: file_fixture('income_proof.pdf').open, filename: 'income_proof.pdf', content_type: 'application/pdf')
      application.medical_certification.attach(io: file_fixture('medical_certification_valid.pdf').open,
                                               filename: 'certification.pdf', content_type: 'application/pdf')
      mark_document_clean!(application.income_proof.blob, user: @admin)
      mark_document_clean!(application.medical_certification.blob, user: @admin, purpose: :certification, slot: 'medical_certification')
      visit admin_application_path(application)
      stale_signed_url = rails_blob_path(application.income_proof)
      proof_path = document_attachment_path(application.income_proof.attachment, disposition: :inline)
      certification_path = document_attachment_path(application.medical_certification.attachment, disposition: :attachment)
      assert_selector "a[href='#{certification_path}']"

      travel 16.minutes do
        first('[data-modal-id="incomeProofReviewModal"]').click
        assert_selector '#incomeProofReviewModal[open]'
        frame_url = find('#incomeProofReviewModal iframe')['src']
        assert_includes frame_url, proof_path
        proof_response = browser_download(frame_url)
        assert_equal 200, proof_response.fetch('status')
        assert_equal application.income_proof.blob.byte_size, proof_response.fetch('bytes')
        assert_equal 'application/pdf', proof_response.fetch('content_type')
        assert_equal 404, browser_download(stale_signed_url).fetch('status')
        certification_response = browser_download(certification_path)
        assert_equal 200, certification_response.fetch('status')
        assert_equal application.medical_certification.blob.byte_size, certification_response.fetch('bytes')
        take_screenshot('proof-modal-after-download-url-expiry', html: true, full: true)
      end
    end

    private

    def browser_download(url)
      page.evaluate_async_script(<<~JS, url)
        const callback = arguments[arguments.length - 1];
        fetch(arguments[0], { credentials: "same-origin" }).then(async response => {
          callback({ status: response.status, bytes: (await response.arrayBuffer()).byteLength,
            content_type: response.headers.get("Content-Type")?.split(";")[0] });
        }).catch(error => callback({ error: error.name }));
      JS
    end
  end
end
