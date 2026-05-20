# frozen_string_literal: true

require 'test_helper'

class SecureProofFormResendsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @application = create(:application, :in_progress)
    Rails.cache.clear
    @raw_token = SecureRequestForm.generate_public_token
    @secure_request_form = create(:secure_request_form,
                                  :expired,
                                  kind: :income_proof_resubmission,
                                  application: @application,
                                  raw_token: @raw_token)
  end

  test 'new renders expired proof resend form' do
    get new_secure_proof_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'form[action=?]', secure_proof_form_resend_path
  end

  test 'new with blank token renders unavailable' do
    get new_secure_proof_form_resend_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.unavailable.heading')
  end

  test 'new with submitted token renders unavailable' do
    @secure_request_form.update!(status: :submitted, submitted_at: Time.current)

    get new_secure_proof_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.unavailable.heading')
  end

  test 'new redirects active link back to upload form' do
    @secure_request_form.update!(expires_at: 1.hour.from_now)

    get new_secure_proof_form_resend_path(token: @raw_token)

    assert_redirected_to secure_proof_form_path(token: @raw_token)
  end

  test 'new uses recipient Spanish locale' do
    @secure_request_form.recipient.update!(locale: 'es')

    get new_secure_proof_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.new.heading', locale: :es)
  end

  test 'create calls resend service and renders neutral response' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::RequestProofResubmission.any_instance.expects(:call).returns(result)

    post secure_proof_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.create.heading')
  end

  test 'create has secure no-store headers' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::RequestProofResubmission.any_instance.stubs(:call).returns(result)

    post secure_proof_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'create logs service failure while rendering neutral response' do
    result = BaseService::Result.new(success: false, message: 'delivery failed', data: {})
    Applications::RequestProofResubmission.any_instance.stubs(:call).returns(result)
    Rails.logger.expects(:warn).with(regexp_matches(/Proof resubmission resend request failed/))

    post secure_proof_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.create.heading')
  end

  test 'create is neutral when rate limited' do
    RateLimit.stubs(:check!).raises(RateLimit::ExceededError)
    Applications::RequestProofResubmission.any_instance.expects(:call).never

    post secure_proof_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.create.heading')
  end

  test 'create is neutral when real rate limit is exceeded' do
    policy_actor = create(:admin)
    proof_limit_policy = Policy.find_or_initialize_by(key: 'proof_submission_rate_limit_web')
    proof_limit_policy.updated_by = policy_actor
    proof_limit_policy.update!(value: 1)
    proof_period_policy = Policy.find_or_initialize_by(key: 'proof_submission_rate_period')
    proof_period_policy.updated_by = policy_actor
    proof_period_policy.update!(value: 1)
    cache_key = 'rate_limit:proof_submission:web:secure_proof_form_resend:127.0.0.1'
    Rails.cache.stubs(:read).with(cache_key).returns(0, 1)
    Rails.cache.stubs(:increment).with(cache_key, 1, has_entry(expires_in: 1.hour)).returns(1)
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::RequestProofResubmission.any_instance.expects(:call).once.returns(result)

    post secure_proof_form_resend_path, params: { token: @raw_token }
    post secure_proof_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.create.heading')
  end

  test 'create with provider info token does not request proof resend' do
    provider_token = SecureRequestForm.generate_public_token
    provider_form = create(:secure_request_form,
                           :expired,
                           kind: :provider_info_request,
                           application: @application,
                           raw_token: provider_token)
    Applications::RequestProofResubmission.any_instance.expects(:call).never

    post secure_proof_form_resend_path, params: { token: provider_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_form_resends.create.heading')
    assert_predicate provider_form.reload, :kind_provider_info_request?
  end
end
