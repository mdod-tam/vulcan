# frozen_string_literal: true

require 'test_helper'

class SecureCertificationFormResendsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @application = create(:application, :in_progress,
                          medical_provider_name: 'Dr. Provider',
                          medical_provider_email: 'provider@example.com')
    Rails.cache.clear
    @raw_token = MedicalProviderSecureRequestForm.generate_public_token
    @secure_request_form = create(:medical_provider_secure_request_form,
                                  :expired,
                                  application: @application,
                                  raw_token: @raw_token)
  end

  test 'new renders expired certification resend form' do
    get new_secure_certification_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'form[action=?]', secure_certification_form_resend_path
  end

  test 'new with blank token renders unavailable' do
    get new_secure_certification_form_resend_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.unavailable.heading')
  end

  test 'new with submitted token renders unavailable' do
    @secure_request_form.update!(status: :submitted, submitted_at: Time.current)

    get new_secure_certification_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.unavailable.heading')
  end

  test 'new redirects active link back to upload form' do
    @secure_request_form.update!(expires_at: 1.hour.from_now)

    get new_secure_certification_form_resend_path(token: @raw_token)

    assert_redirected_to secure_certification_form_path(token: @raw_token)
  end

  test 'new uses application user Spanish locale' do
    @application.user.update!(locale: 'es')

    get new_secure_certification_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.new.heading', locale: :es)
  end

  test 'create calls resend service and renders neutral response' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::RequestCertificationUpload.any_instance.expects(:call).returns(result)

    post secure_certification_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.create.heading')
  end

  test 'create has secure no-store headers' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::RequestCertificationUpload.any_instance.stubs(:call).returns(result)

    post secure_certification_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'create logs service failure while rendering neutral response' do
    result = BaseService::Result.new(success: false, message: 'delivery failed', data: {})
    Applications::RequestCertificationUpload.any_instance.stubs(:call).returns(result)
    Rails.logger.expects(:warn).with(regexp_matches(/Certification upload resend request failed/))

    post secure_certification_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.create.heading')
  end

  test 'create is neutral when rate limited' do
    RateLimit.stubs(:check!).raises(RateLimit::ExceededError)
    Applications::RequestCertificationUpload.any_instance.expects(:call).never

    post secure_certification_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.create.heading')
  end

  test 'create with invalid token does not request resend' do
    Applications::RequestCertificationUpload.any_instance.expects(:call).never

    post secure_certification_form_resend_path, params: { token: 'not-real' }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.create.heading')
  end

  test 'create with proof resubmission token does not request certification upload' do
    # A SecureRequestForm token (different table/model) must not trigger the cert upload flow.
    proof_token = SecureRequestForm.generate_public_token
    create(:secure_request_form, :expired, kind: :id_proof_resubmission,
                                           application: @application, raw_token: proof_token)
    Applications::RequestCertificationUpload.any_instance.expects(:call).never

    post secure_certification_form_resend_path, params: { token: proof_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_form_resends.create.heading')
  end
end
