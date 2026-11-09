# frozen_string_literal: true

require 'test_helper'

class ContactChangesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
    @user = create(:constituent)
    @old_email = @user.email
    @old_phone = @user.phone
    @new_email = "contact-new-#{SecureRandom.hex(5)}@example.com"
    sign_in
  end

  test 'synthetic email proposals cannot create a proof record or send mail' do
    User.expects(:find_by_email).never
    User.expects(:find_by_phone).never
    EmailDelivery.expects(:issuance).never
    ContactChangeDeliveryJob.expects(:perform_later).never

    assert_no_difference ['User.count', 'Session.count', 'ContactChangeRequest.count'] do
      post contact_changes_path,
           params: { contact_change_request: { kind: 'email', proposed_value: ' DEPENDENT@SYSTEM.MATVULCAN.LOCAL ' } }
    end

    assert_response :unprocessable_content
    assert_equal @old_email, @user.reload.email
  end

  test 'password account requires both email proofs and keeps old authority until completion' do
    reset_token = @user.generate_token_for(:password_reset)
    other_browser = open_session
    sign_in(other_browser)
    change = request_email
    assert change.old_confirmation_required?
    assert_equal @old_email, @user.reload.email
    assert_nil change.completed_at
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']

    get contact_verification_path(purpose: 'new_email', token: change.proof_token('new_email'))
    assert_response :success
    assert_nil change.reload.new_confirmed_at, 'A scanner GET cannot consume ownership proof'

    confirm_email(change, 'new_email')
    post complete_contact_change_path(change)
    assert_redirected_to contact_change_path(change)
    assert_response :see_other
    assert_equal @old_email, @user.reload.email
    assert_nil change.reload.completed_at

    confirm_email(change, 'old_email')
    assert_equal @old_email, @user.reload.email
    assert User.find_by_token_for(:password_reset, reset_token)
    post complete_contact_change_path(change)

    assert_redirected_to sign_in_path
    assert_response :see_other
    assert_equal @new_email, @user.reload.email
    assert change.reload.completed_at
    assert_empty @user.sessions
    assert_nil User.find_by_token_for(:password_reset, reset_token)
    other_browser.get edit_profile_path
    other_browser.assert_redirected_to sign_in_path
    assert_equal @old_email, change.notification_email
    assert_equal @old_email, change.delivery_email('old_completed')
    assert_equal @new_email, change.delivery_email('new_completed')
    post contact_verification_path(purpose: 'new_email', token: change.proof_token('new_email'))
    assert_response :unprocessable_content
    assert_equal @new_email, @user.reload.email
  end

  test 'full password and TOTP sign in requires only proposed email proof' do
    delete sign_out_path
    credential = @user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Account app', last_used_at: 1.minute.ago)
    sign_in(credential: credential)
    change = request_email
    assert_not change.old_confirmation_required?
    confirm_email(change, 'new_email')
    post complete_contact_change_path(change)
    assert_redirected_to sign_in_path
    assert_equal @new_email, @user.reload.email
    assert TotpCredential.exists?(credential.id)
  end

  test 'checking confirmation status reads email proofs without promoting the contact' do
    change = request_email
    get contact_change_path(change)
    assert_select "form[action='#{contact_change_path(change)}'][method=get] button", text: I18n.t('contact_changes.check_status')
    assert_select "form[action='#{complete_contact_change_path(change)}']", count: 0

    confirm_email(change, 'old_email')
    confirm_email(change, 'new_email')
    ContactChangeDeliveryJob.expects(:perform_later).never
    assert_no_difference ['Session.count', 'Event.count', 'ContactChangeRequest.count'] do
      get contact_change_path(change)
    end
    assert_response :success
    assert_select "form[action='#{complete_contact_change_path(change)}'] button", text: I18n.t('contact_changes.complete')
    assert_equal @old_email, @user.reload.email
    assert_nil change.reload.completed_at
  end

  test 'a notice persistence failure after committed completion still signs out and reports the changed contact' do
    change = request_email
    confirm_email(change, 'old_email')
    confirm_email(change, 'new_email')
    ContactChangeRequest.any_instance.expects(:enqueue_deliveries!).raises(ActiveRecord::RecordInvalid.new(change))

    post complete_contact_change_path(change)

    assert_redirected_to sign_in_path
    assert_response :see_other
    assert_equal I18n.t('contact_changes.completed_notice_failed'), flash[:notice]
    assert_equal @new_email, @user.reload.email
    assert change.reload.completed_at
    assert_empty @user.sessions
    assert_predicate cookies[:session_token], :blank?
    assert_equal 'pending', change.delivery_states.fetch('old_completed')
    assert_equal 'pending', change.delivery_states.fetch('new_completed')
    assert_equal 1, Event.where(action: 'account_contact_change_completed', auditable: @user).count
    get edit_profile_path
    assert_redirected_to sign_in_path
  end

  test 'a refused notice enqueue after committed completion keeps durable intent and reports the completed change' do
    change = request_email
    confirm_email(change, 'old_email')
    confirm_email(change, 'new_email')
    ContactChangeDeliveryJob.expects(:perform_later).twice.returns(stub(successfully_enqueued?: false))

    post complete_contact_change_path(change)

    assert_redirected_to sign_in_path
    assert_equal I18n.t('contact_changes.completed_notice_failed'), flash[:notice]
    assert_equal @new_email, @user.reload.email
    assert change.reload.completed_at
    assert_predicate cookies[:session_token], :blank?
    assert_equal 'error', change.delivery_states.fetch('old_completed')
    assert_equal 'error', change.delivery_states.fetch('new_completed')
    assert_empty @user.sessions
  end

  test 'another account and another session cannot complete the bound request' do
    change = request_email
    confirm_email(change, 'old_email')
    confirm_email(change, 'new_email')
    stranger = create(:constituent)
    stranger_browser = open_session
    sign_in(stranger_browser, user: stranger)
    stranger_browser.get contact_change_path(change)
    stranger_browser.assert_response :not_found
    stranger_browser.post complete_contact_change_path(change)
    stranger_browser.assert_response :not_found

    second_browser = open_session
    sign_in(second_browser)
    second_browser.post complete_contact_change_path(change)
    second_browser.assert_redirected_to contact_change_path(change)
    assert_equal @old_email, @user.reload.email
    assert_nil change.reload.completed_at
  end

  test 'wrong purpose and tampered proofs cannot mark a destination confirmed' do
    change = request_email
    token = change.proof_token('new_email')
    post contact_verification_path(purpose: 'old_email', token: token)
    assert_response :unprocessable_content
    post contact_verification_path(purpose: 'new_email', token: "#{token}tampered")
    assert_response :unprocessable_content
    assert_nil change.reload.old_confirmed_at
    assert_nil change.new_confirmed_at
    assert_equal @old_email, @user.reload.email
  end

  test 'expired contact proof remains invalid after fresh authentication is renewed' do
    change = request_email
    token = change.proof_token('new_email')
    travel_to(change.expires_at + 1.second) do
      post contact_verification_path(purpose: 'new_email', token: token)
      assert_response :unprocessable_content
      post reauthentication_path, params: { password: 'password1234', factor_type: 'password' }
      assert_redirected_to edit_profile_path
      post complete_contact_change_path(change)
      assert_redirected_to contact_change_path(change)
      assert_nil change.reload.completed_at
      assert_equal @old_email, @user.reload.email
    end
  end

  test 'stale authentication cannot initiate a contact request' do
    travel 6.minutes do
      assert_no_difference 'ContactChangeRequest.count' do
        post contact_changes_path, params: email_parameters
      end
      assert_redirected_to new_reauthentication_path(return_to: new_contact_change_path)
      assert_response :see_other
      assert_equal @old_email, @user.reload.email
    end
  end

  test 'reauthentication renews the same pending request without authorizing the old bearer' do
    change = request_email
    confirm_email(change, 'old_email')
    confirm_email(change, 'new_email')
    old_cookie = cookies[:session_token]
    travel 6.minutes do
      post complete_contact_change_path(change)
      assert_redirected_to new_reauthentication_path(return_to: contact_change_path(change))
      post reauthentication_path, params: { password: 'password1234', factor_type: 'password', return_to: contact_change_path(change) }
      assert_redirected_to contact_change_path(change)
      new_cookie = cookies[:session_token]
      cookies[:session_token] = old_cookie
      post complete_contact_change_path(change)
      assert_redirected_to sign_in_path
      assert_equal @old_email, @user.reload.email
      cookies[:session_token] = new_cookie
      post complete_contact_change_path(change)
      assert_redirected_to sign_in_path
      assert_equal @new_email, @user.reload.email
    end
  end

  test 'an invalid replacement leaves the earlier pending request usable and input visible' do
    first = request_email
    post contact_changes_path, params: email_parameters(value: 'invalid-email')
    assert_response :unprocessable_content
    assert_select 'input[name="contact_change_request[proposed_value]"][value="invalid-email"]'
    assert first.reload.pending?
    assert_nil first.canceled_at

    replacement_email = "replacement-#{SecureRandom.hex(5)}@example.com"
    replacement = request_email(value: replacement_email)
    assert first.reload.canceled_at
    assert replacement.pending?
    post contact_verification_path(purpose: 'new_email', token: first.proof_token('new_email'))
    assert_response :unprocessable_content
  end

  test 'resend preserves the original deadline and cancellation invalidates proof' do
    change = request_email
    original_expiry = change.expires_at
    token = change.proof_token('new_email')
    travel 2.minutes do
      post resend_contact_change_path(change)
      assert_redirected_to contact_change_path(change)
      assert_response :see_other
      assert_equal original_expiry, change.reload.expires_at
      delete contact_change_path(change)
      assert_redirected_to edit_profile_path
      assert_response :see_other
      post contact_verification_path(purpose: 'new_email', token: token)
      assert_response :unprocessable_content
      assert_equal @old_email, @user.reload.email
    end
  end

  test 'a destination collision never adopts or overwrites the other account' do
    existing = create(:constituent)
    change = request_email(value: existing.email)
    confirm_email(change, 'old_email')
    confirm_email(change, 'new_email')
    existing_email = existing.email
    post complete_contact_change_path(change)
    assert_redirected_to contact_change_path(change)
    assert_equal @old_email, @user.reload.email
    assert_equal existing_email, existing.reload.email
    assert_nil change.reload.completed_at
    assert @user.sessions.exists?
  end

  test 'SMS proof is bound to its target and request and does not replace an enrolled factor' do
    delete sign_out_path
    credential = @user.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Account app', last_used_at: 1.minute.ago)
    sms = @user.sms_credentials.create!(phone_number: '443-555-0198', verified_at: Time.current)
    sign_in(credential: credential)
    expires_at = 10.minutes.from_now.to_i
    TwilioVerifyService.expects(:send_verification).returns(success: true, verification_sid: 'VE-contact-test', code_expires_at: expires_at)
    post contact_changes_path, params: { contact_change_request: { kind: 'phone', proposed_value: '4105550191', phone_type: 'text' } }
    change = current_change
    assert_redirected_to contact_change_path(change)
    assert change.sms?
    assert_operator change.sms_expires_at, :<=, Time.zone.at(expires_at)
    assert_equal @old_phone, @user.reload.phone
    post complete_contact_change_path(change)
    assert_nil change.reload.completed_at

    TwilioVerifyService.expects(:check_verification).with(change.proposed_value, '123456', verification_sid: 'VE-contact-test',
                                                                                           purpose: :contact_change, owner: change.sms_owner)
                       .returns(success: true, status: 'approved')
    post verify_sms_contact_change_path(change), params: { code: '123456' }
    assert_redirected_to contact_change_path(change)
    assert_response :see_other
    post complete_contact_change_path(change)
    assert_redirected_to sign_in_path
    assert_equal PhoneNumber.normalize('4105550191'), @user.reload.phone
    assert_equal 'text', @user.phone_type
    assert_equal PhoneNumber.normalize('4435550198'), sms.reload.phone_number
    assert TotpCredential.exists?(credential.id)
  end

  test 'voice number requires staff assistance and cannot be promoted by self service' do
    get new_contact_change_path
    assert_response :success
    assert_select '#contact_change_request_phone_type[aria-describedby=contact-staff-help]'
    assert_select "#contact-staff-help a[href='mailto:#{ProgramContact.support_email}']"
    assert_select "#contact-staff-help a[href='tel:#{ProgramContact.support_phone}']"

    TwilioVerifyService.expects(:send_verification).never
    post contact_changes_path, params: { contact_change_request: { kind: 'phone', proposed_value: '4105550192', phone_type: 'voice' } }
    change = current_change
    assert change.staff_assistance?
    get contact_change_path(change)
    assert_response :success
    assert_select 'input[name=code]', count: 0
    assert_select "a[href='mailto:#{ProgramContact.support_email}']"
    assert_select "a[href='tel:#{ProgramContact.support_phone}']"
    assert_select "form[action='#{resend_contact_change_path(change)}']", count: 0
    assert_select "form[action='#{contact_change_path(change)}'][method=get]", count: 0
    post complete_contact_change_path(change)
    assert_redirected_to contact_change_path(change)
    assert_equal @old_phone, @user.reload.phone
    assert_nil change.reload.completed_at
  end

  test 'removing an optional phone requires fresh authentication and creates no empty proof' do
    post contact_changes_path, params: { contact_change_request: { kind: 'phone', proposed_value: '', phone_type: 'text' } }
    change = current_change
    assert change.ready?
    assert_not change.sms?
    post complete_contact_change_path(change)
    assert_redirected_to sign_in_path
    assert_nil @user.reload.phone
    assert change.reload.completed_at
  end

  test 'legacy generic profile posts cannot write primary contact but ordinary edits still work' do
    first_name = @user.first_name
    patch profile_path, params: { user: { first_name: 'Attempted', email: @new_email } }
    assert_response :unprocessable_content
    assert_equal @old_email, @user.reload.email
    assert_equal first_name, @user.first_name
    patch profile_path, params: { user: { first_name: 'Updated', email: @old_email, phone: @old_phone, phone_type: @user.phone_type } }
    assert_redirected_to constituent_portal_dashboard_path
    assert_equal 'Updated', @user.reload.first_name
    assert_equal @old_email, @user.email
  end

  test 'staff contact correction requires recorded proof at the live admin route' do
    target_browser = open_session
    sign_in(target_browser)
    delete sign_out_path
    admin = create(:admin)
    credential = admin.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Staff app', last_used_at: 1.minute.ago)
    sign_in(user: admin, credential: credential)
    attributes = { phone: '4105550193', phone_type: 'voice' }
    patch admin_user_path(@user), params: { user: attributes }
    assert_response :unprocessable_content
    assert_equal @old_phone, @user.reload.phone

    patch admin_user_path(@user), params: {
      user: attributes,
      contact_verification: { method: 'Approved non-SMS check', reference: 'CASE-789', identity_verified: '1', association_verified: '1' }
    }
    assert_redirected_to admin_user_path(@user)
    assert_equal PhoneNumber.normalize('4105550193'), @user.reload.phone
    assert_empty @user.sessions
    assert admin.sessions.exists?
    target_browser.get edit_profile_path
    target_browser.assert_redirected_to sign_in_path
    change = current_change
    assert change.completed_at
    event = Event.find_by!(action: 'account_contact_change_completed', auditable: @user)
    assert_equal 'CASE-789', event.metadata.dig('verification', 'reference')
  end

  test 'vendor profile contact posts are rejected without breaking unrelated business edits' do
    delete sign_out_path
    vendor = create(:vendor_user)
    credential = vendor.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Vendor app', last_used_at: 1.minute.ago)
    sign_in(user: vendor, credential: credential)
    original_email = vendor.email
    patch vendor_portal_profile_path, params: { users_vendor: { email: @new_email } }
    assert_response :unprocessable_content
    assert_equal original_email, vendor.reload.email
    patch vendor_portal_profile_path, params: { users_vendor: { business_name: 'Updated vendor business' } }
    assert_redirected_to vendor_portal_dashboard_path
    assert_equal 'Updated vendor business', vendor.reload.business_name
    assert_equal original_email, vendor.email
  end

  private

  def sign_in(browser = self, user: @user, credential: nil)
    browser.post sign_in_path, params: { contact: user.email, password: 'password1234' }
    if credential
      browser.assert_response :redirect
      browser.post process_verification_two_factor_authentication_path(type: 'totp'),
                   params: { code: ROTP::TOTP.new(credential.secret).now }, as: :json
      browser.assert_response :success
    else
      browser.assert_redirected_to constituent_portal_dashboard_path
    end
  end

  def email_parameters(value: @new_email)
    { contact_change_request: { kind: 'email', proposed_value: value, phone_type: 'text' } }
  end

  def request_email(value: @new_email)
    post contact_changes_path, params: email_parameters(value: value)
    row = current_change
    assert_redirected_to contact_change_path(row)
    assert_response :see_other
    row
  end

  def current_change
    ContactChangeRequest.where(user_id: @user.id).order(:id).last
  end

  def confirm_email(change, purpose)
    post contact_verification_path(purpose: purpose, token: change.proof_token(purpose))
    assert_response :see_other
    follow_redirect!
    assert_response :success
    change.reload
  end
end
