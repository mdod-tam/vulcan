# frozen_string_literal: true

require 'application_system_test_case'

class HotwireFormFeedbackTest < ApplicationSystemTestCase
  test 'confirmations protect admin actions and vendor validation supports retry' do
    @confirmations = []
    FeatureFlag.disable!(:vouchers_enabled)
    application = create(:application, :completed, :voucher_fulfillment)
    %i[income_proof residency_proof id_proof].each do |proof|
      application.public_send(proof).attach(
        io: Rails.root.join('test/fixtures/files/sample.png').open,
        filename: "#{proof}.png", content_type: 'image/png'
      )
    end
    application.save!
    FeatureFlag.enable!(:vouchers_enabled)
    assert application.can_create_voucher?
    recovery = create(:recovery_request)
    credential = create(:webauthn_credential, user: recovery.user)
    system_test_sign_in(create(:admin))

    visit admin_recovery_requests_path
    confirm_action('Approve Reset', accept: false)
    assert recovery.reload.pending?
    assert WebauthnCredential.exists?(credential.id)
    capture('hotwire-recovery-index-cancelled')

    visit admin_recovery_request_path(recovery)
    confirm_action('Approve Security Key Reset', accept: false)
    assert recovery.reload.pending?
    assert WebauthnCredential.exists?(credential.id)
    capture('hotwire-recovery-details-cancelled')
    confirm_action('Approve Security Key Reset', accept: true)
    assert_current_path admin_recovery_requests_path
    assert_equal 'approved', recovery.reload.status
    assert_not WebauthnCredential.exists?(credential.id)
    capture('hotwire-recovery-approved')

    visit admin_application_path(application)
    confirm_action('Assign Voucher', accept: false)
    assert_empty application.vouchers.reload
    confirm_action('Mark Evaluation Needed', accept: false)
    assert_nil application.reload.evaluation_requested_at
    capture('hotwire-application-actions-cancelled')
    confirm_action('Assign Voucher', accept: true)
    assert_button 'Cancel Voucher'
    voucher = application.vouchers.reload.sole
    confirm_action('Cancel Voucher', accept: false)
    assert voucher.reload.voucher_active?
    capture('hotwire-voucher-cancellation-declined')
    confirm_action('Cancel Voucher', accept: true)
    assert_text 'Voucher cancelled successfully'
    assert voucher.reload.voucher_cancelled?
    visit admin_application_path(application)
    assert_no_button 'Cancel Voucher'
    confirm_action('Mark Evaluation Needed', accept: true)
    assert_selector '[data-testid="evaluation-request-pending"]'
    assert application.reload.evaluation_requested_at.present?
    capture('hotwire-application-actions-confirmed')

    Capybara.reset_sessions!
    install_stimulus_error_reporting
    vendor = create(:vendor, :with_w9, terms_accepted_at: 1.day.ago)
    original_name = vendor.business_name
    system_test_sign_in(vendor)
    visit edit_vendor_portal_profile_path
    fields = {
      business_name: 'Revised Business', business_tax_id: '123456789', website_url: 'ftp://example.com',
      physical_address_1: '42 New Street', physical_address_2: 'Suite 3', city: 'Baltimore', state: 'MD',
      zip_code: '21201', phone: '410-555-1234', email: "revised-#{vendor.id}@example.com"
    }
    fill_profile(fields)
    page.execute_script(<<~JS)
      window.__profileRenders = 0;
      document.addEventListener('turbo:render', () => {
        document.documentElement.dataset.profileRenders = String(++window.__profileRenders);
      });
    JS
    2.times do |index|
      click_button 'Save Changes'
      assert_selector "html[data-profile-renders='#{index + 1}']", visible: :all
      assert_text 'Website url must be a valid URL starting with http:// or https://'
      fields.each { |field, value| assert_field "users_vendor_#{field}", with: value }
      assert_text 'Current W9 form: w9.pdf'
      assert_selector 'input[name="users_vendor[terms_accepted]"][value="1"]', visible: :all
      assert_button 'Save Changes', disabled: false
      assert_equal original_name, vendor.reload.business_name
    end
    capture('hotwire-vendor-validation-retry')
    page.current_window.resize_to(390, 844)
    capture('hotwire-vendor-validation-narrow')
    page.current_window.resize_to(1200, 800)
    corrected = {
      business_name: 'Final Business', business_tax_id: '987654321', website_url: '',
      physical_address_1: '51 Final Street', physical_address_2: '', city: 'Alexandria', state: 'VA',
      zip_code: '21204', phone: '410-555-9876', email: "final-#{vendor.id}@example.com"
    }
    fill_profile(corrected)
    attach_file 'Upload New W9', Rails.root.join('test/fixtures/files/sample_w9.pdf')
    click_button 'Save Changes'
    assert_current_path vendor_portal_dashboard_path
    vendor.reload
    corrected.each { |field, value| assert_equal value, vendor.public_send(field).to_s }
    assert_equal 'sample_w9.pdf', vendor.w9_form.filename.to_s
    assert vendor.terms_accepted_at.present?
    capture('hotwire-vendor-profile-saved')
  end

  private

  def confirm_action(button, accept:)
    message = public_send(accept ? :accept_confirm : :dismiss_confirm) { click_button button }
    assert message.present?
    @confirmations << { button: button, accepted: accept, message: message }
  end

  def fill_profile(fields)
    fields.each { |field, value| fill_in "users_vendor_#{field}", with: value }
  end

  def capture(label)
    assert_empty page.evaluate_script('window.__systemTestErrors')
    @screenshot_artifact_label = label
    increment_unique
    page.save_screenshot(image_path, full: true) # rubocop:disable Lint/Debugger -- Required rendered-flow evidence.
    File.write(image_path.sub(/\.png\z/, '.html'), page.html)
    write_screenshot_sidecar(image_path, label: label, html_saved: true)
    File.write(image_path.sub(/\.png\z/, '.confirmations.json'), JSON.pretty_generate(@confirmations))
    puts screenshot_log_message(image_path)
  ensure
    @screenshot_artifact_label = nil
  end
end
