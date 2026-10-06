# frozen_string_literal: true

require 'test_helper'
require 'rake'

class SystemAuditActorSafetyTest < ActionDispatch::IntegrationTest
  METRIC_ACTIONS = %w[income_proof_attached residency_proof_attached income_proof_attachment_failed residency_proof_attachment_failed].freeze

  setup do
    @admin = create(:admin)
    User.where(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL).find_each do |user|
      user.update!(email: "displaced-#{user.id}@example.test")
    end
    Event.where(action: METRIC_ACTIONS).delete_all
    Rails.cache.clear
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Current.reset
    EmailDelivery::Current.reset
  end

  %i[missing constituent].each do |actor_state|
    test "metrics alert with #{actor_state} actor cannot create or promote an administrator" do
      register_conflicting_constituent if actor_state == :constituent
      5.times { Event.create!(action: 'income_proof_attachment_failed', user: @admin, auditable: @admin) }
      purposes = []
      subscriber = ->(*args) { purposes << args.last[:purpose] }

      ActiveSupport::Notifications.subscribed(subscriber, 'system_audit_actor_missing') do
        assert_no_difference ['User.count', 'Notification.count'] do
          ProofAttachmentMetricsJob.perform_now
        end
      end

      assert_includes purposes, 'system operation'
      assert_system_identity_unchanged
    end

    test "public resends with #{actor_state} actor preserve expired requests without issuing replacements" do
      register_conflicting_constituent if actor_state == :constituent
      application = create(:application, :in_progress, medical_provider_email: 'provider@example.test')
      vendor = create(:vendor)
      cases = [
        [:secure_request_form, { application: application, kind: :provider_info_request }, secure_provider_info_form_resend_path],
        [:secure_request_form, { application: application, kind: :income_proof_resubmission }, secure_proof_form_resend_path],
        [:medical_provider_secure_request_form, { application: application }, secure_certification_form_resend_path],
        [:vendor_secure_request_form, { vendor: vendor }, secure_w9_form_resend_path]
      ]

      cases.each do |factory, attributes, path|
        token = SecureRandom.urlsafe_base64(32)
        form = create(factory, :expired, **attributes, requested_by: nil, raw_token: token)
        counts = ['User.count', 'Event.count', 'Notification.count', 'SecureRequestForm.count',
                  'MedicalProviderSecureRequestForm.count', 'VendorSecureRequestForm.count']
        assert_no_difference counts do
          post path, params: { token: token }
        end
        assert_response :see_other
        assert_not form.reload.revoked?
        follow_redirect!
        assert_response :success
      end

      assert_system_identity_unchanged
      assert_empty ActionMailer::Base.deliveries
    end

    test "certification upload with #{actor_state} actor fails before storing or submitting" do
      register_conflicting_constituent if actor_state == :constituent
      application = create(:application, :in_progress, medical_provider_email: 'provider@example.test')
      token = MedicalProviderSecureRequestForm.generate_public_token
      form = create(:medical_provider_secure_request_form, application: application, raw_token: token)
      file = fixture_file_upload('medical_certification_valid.pdf', 'application/pdf')
      counts = ['User.count', 'Event.count', 'ActiveStorage::Blob.count', 'ActiveStorage::Attachment.count', 'ApplicationStatusChange.count']

      assert_no_difference counts do
        patch secure_certification_form_path, params: { token: token, file: file }
      end

      assert_response :unprocessable_content
      assert_select 'input[type=file][name=file]'
      assert_includes response.body, I18n.t('applications.certification_upload.messages.attachment_failed')
      assert_not form.reload.submitted?
      assert_not application.reload.medical_certification.attached?
      assert_system_identity_unchanged
    end

    test "DocuSeal callback with #{actor_state} actor requests retry before changing the application" do
      register_conflicting_constituent if actor_state == :constituent
      application = create(:application, :in_progress, document_signing_service: 'docuseal',
                                                       document_signing_submission_id: 'actor-probe', document_signing_status: :sent)
      payload = { event_type: 'form.viewed', data: { submission_id: 'actor-probe' } }
      secret = 'system-actor-test-secret'
      Rails.application.credentials.stubs(:webhook_secret).returns(secret)
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, payload.to_json)

      assert_no_difference ['User.count', 'Event.count'] do
        post webhooks_docuseal_medical_certification_path, params: payload,
                                                           headers: { 'X-Webhook-Signature' => signature }, as: :json
      end

      assert_response :service_unavailable
      assert_equal 'sent', application.reload.document_signing_status
      assert_system_identity_unchanged
    end
  end

  test 'policy seeding with no system actor stops before changing policies' do
    Rake::Task.define_task(:environment)
    load Rails.root.join('lib/tasks/seed_policies.rake') unless Rake::Task.task_defined?('db:seed_policies')
    task = Rake::Task['db:seed_policies']
    task.reenable
    original_policies = Policy.order(:id).pluck(:id, :value)

    assert_no_difference ['User.count', 'Policy.count', 'PolicyChange.count'] do
      capture_io { assert_raises(SystemExit) { task.invoke } }
    end

    assert_equal original_policies, Policy.order(:id).pluck(:id, :value)
  end

  private

  def register_conflicting_constituent
    post sign_up_path, params: { user: {
      email: PublicAuditActor::SYSTEM_AUDIT_EMAIL, password: 'password1234', password_confirmation: 'password1234',
      first_name: 'Synthetic', last_name: "SystemActor#{SecureRandom.hex(4)}", date_of_birth: '1991-02-03',
      phone: nil, phone_type: 'contact_email', timezone: 'Eastern Time (US & Canada)', locale: 'en', hearing_disability: true
    } }
    @conflicting_user = User.find_by!(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    assert_equal 'Users::Constituent', @conflicting_user.type
    @password_digest = @conflicting_user.password_digest
    reset!
    Current.reset
    ActionMailer::Base.deliveries.clear
  end

  def assert_system_identity_unchanged
    assert_nil User.system_user
    if @conflicting_user
      user = User.find(@conflicting_user.id)
      assert_equal 'Users::Constituent', user.type
      assert_equal @password_digest, user.password_digest
      assert user.authenticate('password1234')
    else
      assert_nil User.find_by(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    end
  end
end
