# frozen_string_literal: true

require 'test_helper'

class SecureCertificationFormsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @application = create(:application, :in_progress,
                          medical_provider_name: 'Dr. Provider',
                          medical_provider_email: 'provider@example.com')
    @raw_token = MedicalProviderSecureRequestForm.generate_public_token
    @secure_request_form = create(:medical_provider_secure_request_form,
                                  application: @application,
                                  raw_token: @raw_token)
  end

  test 'show renders active certification upload form' do
    get secure_certification_form_path(token: @raw_token)

    assert_response :success
    assert_select 'form[action*=?]', secure_certification_form_path
    assert_select '#file_help', I18n.t('secure_certification_forms.show.file_help')
    assert_select 'input[type=file][name=file][aria-describedby=file_help]'
    assert_select 'button[type=submit]', I18n.t('secure_certification_forms.show.submit')
  end

  test 'show with blank token renders unavailable' do
    get secure_certification_form_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_forms.unavailable.heading')
  end

  test 'show with submitted token renders already submitted state' do
    @secure_request_form.mark_submitted!

    get secure_certification_form_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_forms.submitted.heading')
  end

  test 'show redirects expired token to resend' do
    @secure_request_form.update!(expires_at: 1.minute.ago)

    get secure_certification_form_path(token: @raw_token)

    assert_redirected_to new_secure_certification_form_resend_path(token: @raw_token)
  end

  test 'show uses application user Spanish locale' do
    @application.user.update!(locale: 'es')

    get secure_certification_form_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_forms.show.heading', locale: :es)
  end

  test 'success response has secure no-store headers' do
    get secure_certification_form_success_path

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'patch revoked token renders unavailable' do
    @secure_request_form.revoke!

    patch secure_certification_form_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_forms.unavailable.heading')
  end

  test 'patch expired token redirects to resend' do
    @secure_request_form.update!(expires_at: 1.minute.ago)

    patch secure_certification_form_path, params: { token: @raw_token }

    assert_redirected_to new_secure_certification_form_resend_path(token: @raw_token)
  end

  test 'patch with blank token renders unavailable' do
    patch secure_certification_form_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_forms.unavailable.heading')
  end

  test 'patch submitted token renders already submitted state' do
    @secure_request_form.mark_submitted!

    patch secure_certification_form_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_certification_forms.submitted.heading')
  end

  test 'patch success redirects to success' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::SubmitCertificationUpload.any_instance.stubs(:call).returns(result)
    file = fixture_file_upload(Rails.root.join('test/fixtures/files/medical_certification_valid.pdf'), 'application/pdf')

    patch secure_certification_form_path, params: { token: @raw_token, file: file }

    assert_redirected_to secure_certification_form_success_path
  end

  test 'patch with missing file re-renders upload form with validation error' do
    patch secure_certification_form_path, params: { token: @raw_token }

    assert_response :unprocessable_content
    assert_select 'h1', I18n.t('secure_certification_forms.show.heading')
    assert_select '#error-summary-title', I18n.t('secure_certification_forms.show.error_summary')
    assert_select '#file_error', I18n.t('applications.certification_upload.messages.file_blank')
    assert_select 'input[type=file][name=file][aria-describedby=?]', 'file_help file_error'
    assert_select 'input[type=hidden][name=token][value=?]', @raw_token
  end

  test 'patch with disallowed MIME type re-renders upload form with validation error' do
    Tempfile.create(['certification-upload', '.txt']) do |file|
      file.write('not an accepted certification document ' * 80)
      file.rewind

      upload = Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: 'certification.txt')

      patch secure_certification_form_path, params: { token: @raw_token, file: upload }
    end

    assert_response :unprocessable_content
    assert_select '#error-summary-title', I18n.t('secure_certification_forms.show.error_summary')
    assert_select '#file_error', I18n.t('applications.certification_upload.messages.file_type_invalid')
    assert_select 'input[type=hidden][name=token][value=?]', @raw_token
  end
end
