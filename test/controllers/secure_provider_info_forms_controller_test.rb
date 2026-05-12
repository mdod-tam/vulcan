# frozen_string_literal: true

require 'test_helper'

class SecureProviderInfoFormsControllerTest < ActionDispatch::IntegrationTest
  test 'request locale is scoped to the secure form recipient and reset after rendering' do
    I18n.with_locale(:en) do
      constituent = create(:constituent, locale: 'es')
      application = create(:application, user: constituent)
      token = SecureRequestForm.generate_public_token
      create(:secure_request_form, application: application, recipient: constituent, raw_token: token)

      get secure_provider_info_form_path(token: token)

      assert_response :success
      assert_includes response.body, I18n.t('secure_provider_info_forms.show.heading', locale: :es)
      assert_equal :en, I18n.locale
    end
  end

  test 'public form does not expose existing provider information' do
    application = create(
      :application,
      medical_provider_name: 'Existing Doctor',
      medical_provider_email: 'existing-doctor@example.test',
      medical_provider_phone: '410-555-0199'
    )
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_response :success
    assert_select 'input[value=?]', 'Existing Doctor', count: 0
    assert_no_match 'existing-doctor@example.test', response.body
    assert_no_match '410-555-0199', response.body
  end

  test 'show response uses secure public headers' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'provider name field disables personal-name autocomplete' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_response :success
    assert_select 'input[name=medical_provider_name][autocomplete=off]'
  end

  test 'success page uses the distinct heading copy' do
    get secure_provider_info_form_success_path

    assert_response :success
    assert_select 'h1', text: I18n.t('secure_provider_info_forms.success.heading')
  end

  test 'show with submitted token renders already submitted state' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    secure_request_form = create(:secure_request_form, application: application, recipient: application.user, raw_token: token)
    secure_request_form.mark_submitted!

    get secure_provider_info_form_path(token: token)

    assert_response :success
    assert_select 'h1', text: I18n.t('secure_provider_info_forms.submitted.heading')
  end

  test 'patch submitted token renders already submitted state' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    secure_request_form = create(:secure_request_form, application: application, recipient: application.user, raw_token: token)
    secure_request_form.mark_submitted!

    patch secure_provider_info_form_path(token: token), params: { token: token }

    assert_response :success
    assert_select 'h1', text: I18n.t('secure_provider_info_forms.submitted.heading')
  end

  test 'validation failure preserves token in form action and hidden field' do
    application = create(:application, status: :awaiting_proof)
    application.update!(
      medical_provider_name: nil,
      medical_provider_phone: nil,
      medical_provider_email: nil,
      medical_provider_fax: nil
    )
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: '',
      medical_provider_phone: '',
      medical_provider_email: 'not-an-email'
    }

    assert_response :unprocessable_content
    assert_select "form[action='#{secure_provider_info_form_path(token: token)}']"
    assert_select "input[type=hidden][name=token][value='#{token}']"
  end

  test 'validation failure marks errored fields as aria-invalid' do
    application = create(:application, status: :awaiting_proof)
    application.update!(
      medical_provider_name: nil,
      medical_provider_phone: nil,
      medical_provider_email: nil,
      medical_provider_fax: nil
    )
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: '',
      medical_provider_phone: '',
      medical_provider_email: 'not-an-email'
    }

    assert_response :unprocessable_content
    assert_select 'input#medical_provider_name[aria-invalid=true][aria-describedby=medical_provider_name_error]'
    assert_select 'input#medical_provider_phone[aria-invalid=true][aria-describedby=medical_provider_phone_error]'
    assert_select 'input#medical_provider_email[aria-invalid=true][aria-describedby=medical_provider_email_error]'
    assert_select 'input#medical_provider_fax[aria-invalid=true]', count: 0
  end

  test 'validation failure error summary is focusable and wired to stimulus controller' do
    application = create(:application, status: :awaiting_proof)
    application.update!(
      medical_provider_name: nil,
      medical_provider_phone: nil,
      medical_provider_email: nil,
      medical_provider_fax: nil
    )
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: '',
      medical_provider_phone: '',
      medical_provider_email: 'not-an-email'
    }

    assert_response :unprocessable_content
    assert_select '[role=alert][tabindex="-1"][data-controller="error-summary"]'
    assert_select 'a[data-action="click->error-summary#focus"]', minimum: 1
  end

  test 'error summary links are prefixed with the field label' do
    application = create(:application, status: :awaiting_proof)
    application.update!(
      medical_provider_name: nil,
      medical_provider_phone: nil,
      medical_provider_email: nil,
      medical_provider_fax: nil
    )
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: '',
      medical_provider_phone: '',
      medical_provider_email: 'not-an-email'
    }

    assert_response :unprocessable_content
    name_label = I18n.t('secure_provider_info_forms.show.provider_name')
    email_label = I18n.t('secure_provider_info_forms.show.provider_email')
    assert_select 'a[href="#medical_provider_name"] strong', text: "#{name_label}:"
    assert_select 'a[href="#medical_provider_email"] strong', text: "#{email_label}:"
  end

  test 'generic submit failure renders the service message' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)
    Applications::SubmitProviderInfo.any_instance.stubs(:call).returns(
      BaseService::Result.new(success: false, message: 'This secure request can no longer be used.', data: nil)
    )

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: 'Dr. Taylor',
      medical_provider_phone: '410-555-0199',
      medical_provider_email: 'doctor@example.test'
    }

    assert_response :unprocessable_content
    assert_select '[role=alert]', text: 'This secure request can no longer be used.'
  end

  test 'resend page redirects active tokens back to the form' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)

    get new_secure_provider_info_form_resend_path(token: token)

    assert_redirected_to secure_provider_info_form_path(token: token)
  end

  test 'resend page form opts out of turbo submission' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: application.user, raw_token: token)

    get new_secure_provider_info_form_resend_path(token: token)

    assert_response :success
    assert_select 'form[data-turbo=?]', 'false'
  end

  test 'resend confirmation uses recipient locale without leaking it to later requests' do
    I18n.with_locale(:en) do
      constituent = create(:constituent, locale: 'es')
      application = create(:application, user: constituent)
      token = SecureRequestForm.generate_public_token
      create(:secure_request_form, :expired, application: application, recipient: constituent, raw_token: token)

      post secure_provider_info_form_resend_path, params: { token: token, unexpected_destination: 'attacker@example.test' }

      assert_response :success
      assert_includes response.body, I18n.t('secure_provider_info_form_resends.create.title', locale: :es)
      assert_equal :en, I18n.locale
    end
  end

  test 'resend create does not reissue a still-active token' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)
    Applications::RequestProviderInfo.expects(:new).never

    post secure_provider_info_form_resend_path, params: { token: token }

    assert_response :success
  end

  test 'resend create returns html even when requested as turbo stream' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, application: application, recipient: application.user, raw_token: token)
    Applications::RequestProviderInfo.expects(:new).never

    post secure_provider_info_form_resend_path,
         params: { token: token },
         headers: { 'Accept' => Mime[:turbo_stream].to_s }

    assert_response :success
    assert_equal Mime[:html].to_s, response.media_type
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.create.heading')
  end

  test 'resend create logs service failures while preserving neutral response' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: application.user, raw_token: token)
    Applications::RequestProviderInfo.any_instance.stubs(:call).returns(
      BaseService::Result.new(success: false, message: 'Delivery failed', data: nil)
    )
    Rails.logger.expects(:warn).with(includes('Provider-info resend request failed'))

    post secure_provider_info_form_resend_path, params: { token: token }

    assert_response :success
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.create.heading')
  end

  test 'resend create preserves neutral response when IP rate limited' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: application.user, raw_token: token)
    RateLimit.stubs(:check!).raises(RateLimit::ExceededError)
    Applications::RequestProviderInfo.expects(:new).never
    Rails.logger.expects(:warn).with(includes('Provider-info resend rate limited'))

    post secure_provider_info_form_resend_path, params: { token: token }

    assert_response :success
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.create.heading')
  end

  # -----------------------------------------------------------------------
  # Security headers on success and resend-create responses
  # -----------------------------------------------------------------------

  test 'success page response uses secure public headers' do
    get secure_provider_info_form_success_path

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'resend create response uses secure public headers' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: application.user, raw_token: token)

    post secure_provider_info_form_resend_path, params: { token: token }

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  # -----------------------------------------------------------------------
  # Unavailable show-page states: blank, revoked, submitted tokens
  # -----------------------------------------------------------------------

  test 'show renders unavailable for blank token and returns ok' do
    get secure_provider_info_form_path(token: '')

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading')
    assert_select 'title', text: /#{Regexp.escape(I18n.t!('secure_provider_info_forms.unavailable.title'))}/
  end

  test 'show renders unavailable for unresolvable token and returns ok' do
    get secure_provider_info_form_path(token: 'not-a-real-token-abc123')

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading')
  end

  test 'show renders unavailable for every proof-resubmission token kind' do
    proof_request_kinds.each do |proof_kind|
      application = create(:application)
      token = SecureRequestForm.generate_public_token
      create(:secure_request_form, application: application, recipient: application.user, kind: proof_kind,
                                   raw_token: token)

      get secure_provider_info_form_path(token: token)

      assert_response :ok
      assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading')
    end
  end

  test 'show renders unavailable for revoked token and returns ok' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :revoked, application: application, recipient: application.user, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading')
  end

  test 'show renders already submitted for submitted token and returns ok' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :submitted, application: application, recipient: application.user, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.submitted.heading')
  end

  test 'show redirects expired token to resend page' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: application.user, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_redirected_to new_secure_provider_info_form_resend_path(token: token)
  end

  test 'show renders unavailable body copy in Spanish for a Spanish-locale recipient with revoked token' do
    constituent = create(:constituent, locale: 'es')
    application = create(:application, user: constituent)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :revoked, application: application, recipient: constituent, raw_token: token)

    get secure_provider_info_form_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading', locale: :es)
    assert_includes response.body, I18n.t!('secure_provider_info_forms.unavailable.body', locale: :es)
  end

  test 'raw token does not appear in unavailable show response body' do
    raw_token = 'RAW_TOKEN_SHOULD_NEVER_LEAK_123'
    application = create(:application)
    create(:secure_request_form, :revoked, application: application, recipient: application.user,
                                           raw_token: raw_token)

    get secure_provider_info_form_path(token: raw_token)

    assert_response :ok
    assert_no_match raw_token, response.body
  end

  # -----------------------------------------------------------------------
  # Already-submitted re-POST renders explicit submitted state (no re-submission)
  # -----------------------------------------------------------------------

  test 'PATCH with a revoked token renders unavailable' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :revoked, application: application, recipient: application.user, raw_token: token)

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: 'Dr. Revoked Attempt',
      medical_provider_phone: '410-555-0100',
      medical_provider_email: 'revoked@example.test'
    }

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading')
  end

  test 'PATCH with every proof-resubmission token kind renders unavailable without updating provider info' do
    proof_request_kinds.each do |proof_kind|
      application = create(:application, status: :awaiting_proof)
      application.update!(
        medical_provider_name: nil,
        medical_provider_phone: nil,
        medical_provider_email: nil,
        medical_provider_fax: nil
      )
      token = SecureRequestForm.generate_public_token
      secure_request_form = create(:secure_request_form, application: application, recipient: application.user,
                                                         kind: proof_kind, raw_token: token)

      assert_no_difference -> { Event.where(action: 'medical_provider_info_submitted').count } do
        patch secure_provider_info_form_path(token: token), params: {
          token: token,
          medical_provider_name: 'Dr. Proof Token',
          medical_provider_phone: '410-555-0100',
          medical_provider_email: 'proof-token@example.test'
        }
      end

      assert_response :ok
      assert_select 'h1', I18n.t!('secure_provider_info_forms.unavailable.heading')
      assert_nil application.reload.medical_provider_name
      assert_predicate secure_request_form.reload, :status_sent?
    end
  end

  test 'PATCH with an expired token redirects to resend page' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: application.user, raw_token: token)

    patch secure_provider_info_form_path(token: token), params: {
      token: token,
      medical_provider_name: 'Dr. Expired Attempt',
      medical_provider_phone: '410-555-0100',
      medical_provider_email: 'expired@example.test'
    }

    assert_redirected_to new_secure_provider_info_form_resend_path(token: token)
  end

  test 'PATCH with a submitted token renders submitted state without resubmitting' do
    application = create(:application)
    application.update!(medical_provider_name: 'Dr. Already Submitted',
                        medical_provider_phone: '410-555-0100',
                        medical_provider_email: 'submitted@example.test')
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :submitted, application: application, recipient: application.user, raw_token: token)

    assert_no_difference -> { Event.where(action: 'medical_provider_info_submitted').count } do
      patch secure_provider_info_form_path(token: token), params: {
        token: token,
        medical_provider_name: 'Dr. Second Submit Attempt',
        medical_provider_phone: '410-555-0100',
        medical_provider_email: 'second@example.test'
      }
    end

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_forms.submitted.heading')
    assert_equal 'Dr. Already Submitted', application.reload.medical_provider_name
  end

  # -----------------------------------------------------------------------
  # Resend new: unavailable states
  # -----------------------------------------------------------------------

  test 'resend new renders unavailable for a revoked token' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :revoked, application: application, recipient: application.user, raw_token: token)

    get new_secure_provider_info_form_resend_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.unavailable.heading')
  end

  test 'resend new renders unavailable for a submitted token' do
    application = create(:application)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :submitted, application: application, recipient: application.user, raw_token: token)

    get new_secure_provider_info_form_resend_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.unavailable.heading')
  end

  test 'resend rejects every proof-resubmission token kind without reissuing provider-info request' do
    Applications::RequestProviderInfo.expects(:new).never

    proof_request_kinds.each do |proof_kind|
      application = create(:application)
      token = SecureRequestForm.generate_public_token
      create(:secure_request_form, :expired, application: application, recipient: application.user, kind: proof_kind,
                                             raw_token: token)

      get new_secure_provider_info_form_resend_path(token: token)

      assert_response :ok
      assert_select 'h1', I18n.t!('secure_provider_info_form_resends.unavailable.heading')

      post secure_provider_info_form_resend_path, params: { token: token }

      assert_response :ok
      assert_select 'h1', I18n.t!('secure_provider_info_form_resends.create.heading')
    end
  end

  test 'resend new renders unavailable copy in Spanish for Spanish-locale recipient with revoked token' do
    constituent = create(:constituent, locale: 'es')
    application = create(:application, user: constituent)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :revoked, application: application, recipient: constituent, raw_token: token)

    get new_secure_provider_info_form_resend_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.unavailable.heading', locale: :es)
    assert_includes response.body, I18n.t!('secure_provider_info_form_resends.unavailable.body', locale: :es)
  end

  # -----------------------------------------------------------------------
  # Spanish i18n: resend cooldown and neutral confirmation
  # -----------------------------------------------------------------------

  test 'resend new renders expiry heading in Spanish for Spanish-locale recipient' do
    constituent = create(:constituent, locale: 'es')
    application = create(:application, user: constituent)
    token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, application: application, recipient: constituent, raw_token: token)

    get new_secure_provider_info_form_resend_path(token: token)

    assert_response :ok
    assert_select 'h1', I18n.t!('secure_provider_info_form_resends.new.heading', locale: :es)
    assert_includes response.body, I18n.t!('secure_provider_info_form_resends.new.body', locale: :es)
  end

  private

  def proof_request_kinds
    %i[id_proof_resubmission residency_proof_resubmission income_proof_resubmission]
  end
end
