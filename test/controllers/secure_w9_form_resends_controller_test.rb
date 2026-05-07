# frozen_string_literal: true

require 'test_helper'

class SecureW9FormResendsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @vendor = create(:vendor, :with_w9)
    Rails.cache.clear
    @raw_token = VendorSecureRequestForm.generate_public_token
    @secure_request_form = create(:vendor_secure_request_form,
                                  :expired,
                                  vendor: @vendor,
                                  raw_token: @raw_token)
  end

  test 'new renders expired W9 resend form' do
    get new_secure_w9_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'form[action=?]', secure_w9_form_resend_path
  end

  test 'new with blank token renders unavailable' do
    get new_secure_w9_form_resend_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_form_resends.unavailable.heading')
  end

  test 'new redirects active link back to upload form' do
    @secure_request_form.update!(expires_at: 1.hour.from_now)

    get new_secure_w9_form_resend_path(token: @raw_token)

    assert_redirected_to secure_w9_form_path(token: @raw_token)
  end

  test 'new uses vendor spanish locale' do
    @vendor.update!(locale: 'es')

    get new_secure_w9_form_resend_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_form_resends.new.heading', locale: :es)
  end

  test 'create calls resend service and renders neutral response' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Vendors::RequestW9Resubmission.any_instance.expects(:call).returns(result)

    post secure_w9_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_form_resends.create.heading')
  end

  test 'create logs service failure while rendering neutral response' do
    result = BaseService::Result.new(success: false, message: 'delivery failed', data: {})
    Vendors::RequestW9Resubmission.any_instance.stubs(:call).returns(result)
    Rails.logger.expects(:warn).with(regexp_matches(/W9 resubmission resend request failed/))

    post secure_w9_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_form_resends.create.heading')
  end

  test 'create is neutral when rate limited' do
    RateLimit.stubs(:check!).raises(RateLimit::ExceededError)
    Vendors::RequestW9Resubmission.any_instance.expects(:call).never

    post secure_w9_form_resend_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_form_resends.create.heading')
  end
end
