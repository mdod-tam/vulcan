# frozen_string_literal: true

require 'test_helper'

# Pins the shared behavior of every public secure form and resend endpoint.
# A change to any expected value in this file is a deliberate behavior change.
class SecurePublicFormMatrixTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile

  STATES = %i[missing wrong_kind active expired revoked submitted revoked_submitted].freeze

  FORMS = {
    proof: {
      factory: :secure_request_form, kind: :income_proof_resubmission, wrong_kind: :provider_info_request,
      views: 'secure_proof_forms', resend_views: 'secure_proof_form_resends',
      form_path: :secure_proof_form_path, resend_path: :new_secure_proof_form_resend_path,
      resend_create_path: :secure_proof_form_resend_path, success_path: :secure_proof_form_success_path,
      submit_service: Applications::SubmitProofResubmission, resend_service: Applications::RequestProofResubmission,
      rate_limit_key: 'secure_proof_form_resend',
      sent_path: :secure_proof_form_resend_sent_path
    },
    certification: {
      factory: :medical_provider_secure_request_form, kind: :certification_upload, wrong_kind: nil,
      views: 'secure_certification_forms', resend_views: 'secure_certification_form_resends',
      form_path: :secure_certification_form_path, resend_path: :new_secure_certification_form_resend_path,
      resend_create_path: :secure_certification_form_resend_path, success_path: :secure_certification_form_success_path,
      submit_service: Applications::SubmitCertificationUpload, resend_service: Applications::RequestCertificationUpload,
      rate_limit_key: 'secure_certification_form_resend',
      sent_path: :secure_certification_form_resend_sent_path
    },
    provider_info: {
      factory: :secure_request_form, kind: :provider_info_request, wrong_kind: :income_proof_resubmission,
      views: 'secure_provider_info_forms', resend_views: 'secure_provider_info_form_resends',
      form_path: :secure_provider_info_form_path, resend_path: :new_secure_provider_info_form_resend_path,
      resend_create_path: :secure_provider_info_form_resend_path, success_path: :secure_provider_info_form_success_path,
      submit_service: Applications::SubmitProviderInfo, resend_service: Applications::RequestProviderInfo,
      rate_limit_key: 'secure_provider_info_form_resend',
      sent_path: :secure_provider_info_form_resend_sent_path
    },
    w9: {
      factory: :vendor_secure_request_form, kind: :w9_upload, wrong_kind: nil,
      views: 'secure_w9_forms', resend_views: 'secure_w9_form_resends',
      form_path: :secure_w9_form_path, resend_path: :new_secure_w9_form_resend_path,
      resend_create_path: :secure_w9_form_resend_path, success_path: :secure_w9_form_success_path,
      submit_service: Vendors::SubmitW9Resubmission, resend_service: Vendors::RequestW9Resubmission,
      rate_limit_key: 'secure_w9_form_resend',
      sent_path: :secure_w9_form_resend_sent_path
    }
  }.freeze

  setup do
    Rails.cache.clear
  end

  FORMS.each do |name, config|
    STATES.each do |state|
      next if state == :wrong_kind && config[:wrong_kind].nil?

      test "#{name} show with #{state} link" do
        token, form = build_state(config, state)

        get public_send(config[:form_path], token: token)

        assert_secure_headers
        case expected_show(state)
        when :resend then assert_redirected_to public_send(config[:resend_path], token: token)
        else
          assert_response :ok
          assert_template "#{config[:views]}/#{expected_show(state)}"
        end
        assert_nil form&.reload&.submitted_at if state == :active
      end

      test "#{name} update with #{state} link" do
        token, form = build_state(config, state)
        if state == :active
          config[:submit_service].any_instance.expects(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: nil))
        else
          config[:submit_service].any_instance.expects(:call).never
        end

        patch public_send(config[:form_path]), params: update_params(name, token)

        assert_secure_headers
        # Every update answers with 303 so Turbo follows it to a GET page.
        assert_response :see_other
        case expected_update(state)
        when :resend then assert_redirected_to public_send(config[:resend_path], token: token)
        when :success
          assert_redirected_to public_send(config[:success_path], locale: form.delivery_locale)
        else
          assert_redirected_to public_send(config[:form_path], token: token)
        end
      end

      test "#{name} resend page with #{state} link" do
        token, = build_state(config, state)

        get public_send(config[:resend_path], token: token)

        assert_secure_headers
        case state
        when :active then assert_redirected_to public_send(config[:form_path], token: token)
        when :expired
          assert_response :ok
          assert_template "#{config[:resend_views]}/new"
        else
          assert_response :ok
          assert_template "#{config[:resend_views]}/unavailable"
        end
      end

      test "#{name} resend request with #{state} link" do
        token, = build_state(config, state)
        if state == :expired
          RateLimit.expects(:check!).with(:proof_submission, "#{config[:rate_limit_key]}:127.0.0.1")
          config[:resend_service].any_instance.expects(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: nil))
        else
          config[:resend_service].any_instance.expects(:call).never
        end

        post public_send(config[:resend_create_path]), params: { token: token }

        assert_secure_headers
        assert_response :see_other
        assert_redirected_to public_send(config[:sent_path], locale: 'en')
      end
    end

    test "#{name} resend sent page follows the locale in the redirect" do
      get public_send(config[:sent_path], locale: 'es')

      assert_secure_headers
      assert_response :ok
      assert_template "#{config[:resend_views]}/create"
      assert_select 'html[lang=?]', 'es'
    end

    test "#{name} success page locale" do
      get public_send(config[:success_path], locale: 'es')

      assert_response :ok
      assert_template "#{config[:views]}/success"
      assert_select 'html[lang=?]', 'es'
    end

    test "#{name} form and resend pages follow the delivery locale" do
      token, form = build_state(config, :active)
      spanish_locale_owner(name, form).update!(locale: 'es')
      # Providers get English; the applicant's locale is not the provider's.
      expected = name == :certification ? 'en' : 'es'

      get public_send(config[:form_path], token: token)
      assert_select 'html[lang=?]', expected

      form.update!(expires_at: 1.hour.ago)
      get public_send(config[:resend_path], token: token)
      assert_select 'html[lang=?]', expected
    end
  end

  private

  def build_state(config, state)
    return ['not-a-real-token', nil] if state == :missing

    token = config[:factory].to_s.classify.constantize.generate_public_token
    kind = state == :wrong_kind ? config[:wrong_kind] : config[:kind]
    traits = { expired: [:expired], revoked: [:revoked], submitted: [:submitted] }.fetch(state, [])
    attributes = { kind: kind, raw_token: token }
    attributes[:submitted_at] = Time.current if state == :revoked_submitted
    traits = [:revoked] if state == :revoked_submitted
    [token, create(config[:factory], *traits, **attributes)]
  end

  def expected_show(state)
    case state
    when :missing, :wrong_kind, :revoked then :unavailable
    when :active then :show
    when :expired then :resend
    when :submitted, :revoked_submitted then :submitted
    end
  end

  def expected_update(state)
    case state
    when :missing, :wrong_kind, :revoked, :revoked_submitted, :submitted then :current_state
    when :active then :success
    when :expired then :resend
    end
  end

  def update_params(name, token)
    if name == :provider_info
      return { token: token, medical_provider_name: 'Dr. Matrix', medical_provider_phone: '410-555-0100',
               medical_provider_email: 'matrix@example.test' }
    end

    { token: token, file: fixture_file_upload(Rails.root.join('test/fixtures/files/medical_certification_valid.pdf'), 'application/pdf') }
  end

  def spanish_locale_owner(name, form)
    case name
    when :certification then form.application.user
    when :w9 then form.vendor
    else form.delivery_owner
    end
  end

  def assert_secure_headers
    assert_includes response.headers['Cache-Control'], 'no-store'
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end
end
