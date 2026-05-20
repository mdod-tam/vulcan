# frozen_string_literal: true

require 'test_helper'

class SecureW9FormsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @vendor = create(:vendor, :with_w9)
    @raw_token = VendorSecureRequestForm.generate_public_token
    @secure_request_form = create(:vendor_secure_request_form,
                                  vendor: @vendor,
                                  raw_token: @raw_token)
  end

  test 'show renders active W9 upload form' do
    get secure_w9_form_path(token: @raw_token)

    assert_response :success
    assert_select 'form[action*=?]', secure_w9_form_path
    assert_select '#file_help', I18n.t('secure_w9_forms.show.file_help')
    assert_select 'input[type=file][name=file][aria-describedby=file_help]'
    assert_select 'button[type=submit]', I18n.t('secure_w9_forms.show.submit')
  end

  test 'show with blank token renders unavailable' do
    get secure_w9_form_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_forms.unavailable.heading')
  end

  test 'show with submitted token renders already submitted state' do
    @secure_request_form.mark_submitted!

    get secure_w9_form_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_forms.submitted.heading')
  end

  test 'show redirects expired token to resend' do
    @secure_request_form.update!(expires_at: 1.minute.ago)

    get secure_w9_form_path(token: @raw_token)

    assert_redirected_to new_secure_w9_form_resend_path(token: @raw_token)
  end

  test 'show uses vendor spanish locale' do
    @vendor.update!(locale: 'es')

    get secure_w9_form_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_forms.show.heading', locale: :es)
  end

  test 'success response has secure no-store headers' do
    get secure_w9_form_success_path

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'patch revoked token renders unavailable' do
    @secure_request_form.revoke!

    patch secure_w9_form_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_forms.unavailable.heading')
  end

  test 'patch expired token redirects to resend' do
    @secure_request_form.update!(expires_at: 1.minute.ago)

    patch secure_w9_form_path, params: { token: @raw_token }

    assert_redirected_to new_secure_w9_form_resend_path(token: @raw_token)
  end

  test 'patch submitted token renders already submitted state' do
    @secure_request_form.mark_submitted!

    patch secure_w9_form_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_w9_forms.submitted.heading')
  end

  test 'patch success redirects to success' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Vendors::SubmitW9Resubmission.any_instance.stubs(:call).returns(result)
    file = fixture_file_upload(Rails.root.join('test/fixtures/files/sample_w9.pdf'), 'application/pdf')

    patch secure_w9_form_path, params: { token: @raw_token, file: file }

    assert_redirected_to secure_w9_form_success_path
  end

  test 'patch with missing file re-renders upload form with validation error' do
    patch secure_w9_form_path, params: { token: @raw_token }

    assert_response :unprocessable_content
    assert_select 'h1', I18n.t('secure_w9_forms.show.heading')
    assert_select '#error-summary-title', I18n.t('secure_w9_forms.show.error_summary')
    assert_select '#file_error', I18n.t('vendors.w9_resubmission.messages.file_blank')
    assert_select 'input[type=file][name=file][aria-describedby=?]', 'file_help file_error'
    assert_select 'input[type=hidden][name=token][value=?]', @raw_token
  end
end
