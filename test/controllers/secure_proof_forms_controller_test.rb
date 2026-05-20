# frozen_string_literal: true

require 'test_helper'

class SecureProofFormsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @application = create(:application, :in_progress)
    @raw_token = SecureRequestForm.generate_public_token
    @secure_request_form = create(:secure_request_form,
                                  kind: :income_proof_resubmission,
                                  application: @application,
                                  raw_token: @raw_token)
  end

  test 'show renders active proof upload form' do
    get secure_proof_form_path(token: @raw_token)

    assert_response :success
    assert_select 'form[action*=?]', secure_proof_form_path
    assert_select '#file_help', I18n.t('secure_proof_forms.show.file_help')
    assert_select 'input[type=file][name=file][aria-describedby=file_help]'
    assert_select 'button[type=submit]', I18n.t('secure_proof_forms.show.submit')
  end

  test 'show with blank token renders unavailable' do
    get secure_proof_form_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_forms.unavailable.heading')
  end

  test 'show with submitted token renders already submitted state' do
    @secure_request_form.mark_submitted!

    get secure_proof_form_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_forms.submitted.heading')
  end

  test 'show redirects expired token to resend' do
    @secure_request_form.update!(expires_at: 1.minute.ago)

    get secure_proof_form_path(token: @raw_token)

    assert_redirected_to new_secure_proof_form_resend_path(token: @raw_token)
  end

  test 'show uses recipient Spanish locale' do
    @secure_request_form.recipient.update!(locale: 'es')

    get secure_proof_form_path(token: @raw_token)

    assert_response :success
    assert_select 'h1', I18n.t(
      'secure_proof_forms.show.heading',
      proof_type: I18n.t('secure_proof_forms.proof_types.income', locale: :es),
      locale: :es
    )
  end

  test 'success response has secure no-store headers' do
    get secure_proof_form_success_path

    assert_response :success
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'patch revoked token renders unavailable' do
    @secure_request_form.revoke!

    patch secure_proof_form_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_forms.unavailable.heading')
  end

  test 'patch expired token redirects to resend' do
    @secure_request_form.update!(expires_at: 1.minute.ago)

    patch secure_proof_form_path, params: { token: @raw_token }

    assert_redirected_to new_secure_proof_form_resend_path(token: @raw_token)
  end

  test 'patch with blank token renders unavailable' do
    patch secure_proof_form_path

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_forms.unavailable.heading')
  end

  test 'patch submitted token renders already submitted state' do
    @secure_request_form.mark_submitted!

    patch secure_proof_form_path, params: { token: @raw_token }

    assert_response :success
    assert_select 'h1', I18n.t('secure_proof_forms.submitted.heading')
  end

  test 'patch success redirects to success' do
    result = BaseService::Result.new(success: true, message: 'ok', data: {})
    Applications::SubmitProofResubmission.any_instance.stubs(:call).returns(result)
    file = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')

    patch secure_proof_form_path, params: { token: @raw_token, file: file }

    assert_redirected_to secure_proof_form_success_path
  end

  test 'patch with missing file re-renders upload form with validation error' do
    patch secure_proof_form_path, params: { token: @raw_token }

    assert_response :unprocessable_content
    assert_select 'h1', I18n.t(
      'secure_proof_forms.show.heading',
      proof_type: I18n.t('secure_proof_forms.proof_types.income')
    )
    assert_select '#error-summary-title', I18n.t('secure_proof_forms.show.error_summary')
    assert_select '#file_error', I18n.t('applications.proof_resubmission.messages.file_blank')
    assert_select 'input[type=file][name=file][aria-describedby=?]', 'file_help file_error'
    assert_select 'input[type=hidden][name=token][value=?]', @raw_token
  end

  test 'patch with disallowed MIME type re-renders upload form with validation error' do
    Tempfile.create(['proof-upload', '.txt']) do |file|
      file.write('not an accepted proof document ' * 80)
      file.rewind

      upload = Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: 'proof.txt')

      patch secure_proof_form_path, params: { token: @raw_token, file: upload }
    end

    assert_response :unprocessable_content
    assert_select '#error-summary-title', I18n.t('secure_proof_forms.show.error_summary')
    assert_select '#file_error', I18n.t('applications.proof_resubmission.messages.file_type_invalid')
    assert_select 'input[type=hidden][name=token][value=?]', @raw_token
  end
end
