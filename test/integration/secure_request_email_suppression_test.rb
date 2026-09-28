# frozen_string_literal: true

require 'test_helper'

# Secure-link request owners with real mailers: a denied email creates no request or token,
# and an email stopped after its request was prepared revokes the unsent link without a cooldown.
class SecureRequestEmailSuppressionTest < ActiveSupport::TestCase
  include ProofResubmissionTestHelper

  setup do
    @admin = create(:admin)
    ensure_system_audit_actor!
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Current.reset
  end

  test 'a W9 request with email off creates no request, token, or revocation' do
    vendor = rejected_vendor
    open_request = vendor_request_for(vendor)
    set_email(false, 'op-1')

    result = assert_no_difference('VendorSecureRequestForm.count') do
      Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin).call
    end

    assert result.data[:delivery_suppressed]
    assert_equal 'global_disabled', result.data[:suppression_reason]
    assert_equal I18n.t('vendors.w9_resubmission.messages.delivery_suppressed', locale: :en), result.message
    assert open_request.reload.active?
    assert_empty ActionMailer::Base.deliveries
    assert Event.exists?(action: EmailDelivery::Outcome::SUPPRESSED)
  end

  test 'a turned-off W9 template pair creates no request' do
    vendor = rejected_vendor
    load_seeded_email_templates('vendor_notifications_w9_rejected')
    set_pair('vendor_notifications_w9_rejected', false, 'op-1')

    result = assert_no_difference('VendorSecureRequestForm.count') do
      Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin).call
    end

    assert_equal 'template_disabled', result.data[:suppression_reason]
    assert_empty ActionMailer::Base.deliveries

    set_pair('vendor_notifications_w9_rejected', true, 'op-2')
    assert_predicate Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin).call, :success?
    assert_equal [[vendor.email]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'an email stopped at the final check revokes the prepared link and leaves no cooldown' do
    vendor = rejected_vendor
    load_seeded_email_templates('vendor_notifications_w9_rejected')
    EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                         .then.returns(EmailDelivery::Decision.suppressed(:global_disabled))

    result = Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin).call

    form = result.data.fetch(:vendor_secure_request_form)
    assert result.data[:delivery_suppressed]
    assert form.reload.revoked?
    assert_equal 'delivery_suppressed', Event.where(action: form.revocation_audit_action).order(:id).last.metadata['reason']
    assert_empty ActionMailer::Base.deliveries

    EmailDelivery::Policy.unstub(:verify_delivery)
    assert_predicate Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin).call, :success?
  end

  test 'a certification upload email request with email off changes nothing' do
    application = provider_application
    set_email(false, 'op-1')

    result = assert_no_difference('MedicalProviderSecureRequestForm.count') do
      Applications::RequestCertificationUpload.new(application: application, actor: @admin, deliver_email: true).call
    end

    assert result.data[:delivery_suppressed]
    assert application.reload.medical_certification_status_not_requested?
    assert_empty ActionMailer::Base.deliveries
  end

  test 'a prepare-only certification upload request still works with email off' do
    application = provider_application
    set_email(false, 'op-1')

    result = assert_difference('MedicalProviderSecureRequestForm.count', 1) do
      Applications::RequestCertificationUpload.new(application: application, actor: @admin, deliver_email: false).call
    end

    assert_predicate result, :success?
  end

  test 'a proof resubmission for an email recipient with email off creates no request' do
    application, = rejected_income_application
    set_email(false, 'op-1')

    result = assert_no_difference('SecureRequestForm.count') do
      Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :income).call
    end

    assert result.data[:delivery_suppressed]
    assert_empty ActionMailer::Base.deliveries
  end

  test 'a proof resubmission for a letter recipient still prints with email off' do
    application, = rejected_income_application
    application.user.update!(communication_preference: 'letter')
    load_seeded_email_templates('application_notifications_proof_rejected')
    set_email(false, 'op-1')

    result = assert_difference('SecureRequestForm.count', 1) do
      assert_difference('PrintQueueItem.count', 1) do
        Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :income).call
      end
    end

    assert_predicate result, :success?
    assert_empty ActionMailer::Base.deliveries
  end

  %i[w9 certification provider_info proof].each do |kind|
    test "#{kind} configuration refusal creates no request and is reported as an error" do
      service = configuration_test_service(kind)
      FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL).destroy!
      counts = [SecureRequestForm.count, VendorSecureRequestForm.count, MedicalProviderSecureRequestForm.count]

      result = service.call

      assert result.failure?
      assert result.data&.dig(:configuration_error), result.inspect
      assert_not result.data[:delivery_suppressed]
      assert_equal counts, [SecureRequestForm.count, VendorSecureRequestForm.count, MedicalProviderSecureRequestForm.count]
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test 'DocuSeal configuration refusal is an error and does not call the provider' do
    application = provider_application
    FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL).destroy!
    ::Docuseal.expects(:create_submission).never

    result = DocumentSigning::SubmissionService.new(application: application, actor: @admin).call

    assert result.failure?
    assert result.data&.dig(:configuration_error), result.inspect
    assert_not result.data[:delivery_suppressed]
    assert_nil application.reload.document_signing_requested_at
  end

  %i[provider_info proof].each do |kind|
    test "#{kind} configuration refusal still delivers the other recipient's letter" do
      application = kind == :proof ? rejected_income_application.first : create(:application, :in_progress)
      guardian = create(:constituent)
      create(:guardian_relationship, dependent_user: application.user, guardian_user: guardian)
      application.update!(managing_guardian_id: guardian.id)
      load_seeded_email_templates('application_notifications_provider_info_requested', 'application_notifications_proof_rejected')
      FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL).destroy!
      options = { application: application, actor: @admin, recipient_ids: [application.user_id, guardian.id],
                  channel_overrides: { application.user_id => 'email', guardian.id => 'letter' } }
      service = if kind == :proof
                  Applications::RequestProofResubmission.new(**options, proof_type: :income)
                else
                  Applications::RequestProviderInfo.new(**options)
                end

      result = assert_difference('SecureRequestForm.count', 1) do
        assert_difference('PrintQueueItem.count', 1) { service.call }
      end

      assert result.failure?
      assert result.data[:configuration_error]
      assert_equal [application.user_id], result.data[:failed_recipient_ids]
      assert_equal [guardian.id], result.data[:secure_request_forms].map(&:recipient_id)
      assert_empty ActionMailer::Base.deliveries
    end
  end

  %i[w9 certification].each do |kind|
    test "#{kind} late configuration refusal revokes the link and starts no cooldown" do
      service = configuration_test_service(kind)
      load_seeded_email_templates('vendor_notifications_w9_rejected', 'medical_provider_request_certification')
      EmailDelivery::Policy.stubs(:verify_delivery).returns(EmailDelivery::Decision.allowed)
                           .then.returns(EmailDelivery::Decision.configuration_error(:unavailable))

      result = service.call

      assert result.failure?
      assert result.data[:configuration_error], result.inspect
      key = kind == :w9 ? :vendor_secure_request_form : :medical_provider_secure_request_form
      form = result.data.fetch(key)
      assert form.reload.revoked?
      notification = Notification.where('metadata->>? = ?', "#{key}_id", form.id.to_s).order(:id).last
      assert_equal 'error', notification.delivery_status
      assert_equal 'none', notification.metadata['actual_delivery_channel']
      assert_equal 'unavailable', notification.metadata.dig('delivery_error', 'reason')
      assert_not notification.metadata.key?('delivery_suppressed')
      assert_empty ActionMailer::Base.deliveries

      EmailDelivery::Policy.unstub(:verify_delivery)
      assert_predicate configuration_retry_service(kind, service).call, :success?
    end
  end

  private

  def configuration_test_service(kind)
    case kind
    when :w9
      Vendors::RequestW9Resubmission.new(vendor: rejected_vendor, actor: @admin)
    when :certification
      Applications::RequestCertificationUpload.new(application: provider_application, actor: @admin, deliver_email: true)
    when :provider_info
      Applications::RequestProviderInfo.new(application: create(:application, :in_progress), actor: @admin)
    when :proof
      application, = rejected_income_application
      Applications::RequestProofResubmission.new(application: application, actor: @admin, proof_type: :income)
    end
  end

  def configuration_retry_service(kind, service)
    if kind == :w9
      Vendors::RequestW9Resubmission.new(vendor: service.vendor, actor: @admin)
    else
      Applications::RequestCertificationUpload.new(application: service.application, actor: @admin, deliver_email: true)
    end
  end

  def set_email(enabled, operation_id)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: enabled, actor: @admin,
                                     operation_id: operation_id)
  end

  def set_pair(name, enabled, operation_id)
    EmailDelivery::ControlWriter.set_template_pair(name: name, format: :text, enabled: enabled, actor: @admin,
                                                   operation_id: operation_id)
  end

  def rejected_vendor
    vendor = create(:vendor, :with_w9)
    vendor.update!(w9_status: :rejected)
    W9Review.skip_callback(:commit, :after, :handle_post_review_actions)
    create(:w9_review, :rejected, vendor: vendor, admin: @admin, rejection_reason: 'Tax ID mismatch')
    vendor
  ensure
    W9Review.set_callback(:commit, :after, :handle_post_review_actions, on: :create)
  end

  def vendor_request_for(vendor)
    VendorSecureRequestForm.create!(
      vendor: vendor, kind: :w9_upload, status: :sent, recipient_email: vendor.email,
      public_token_digest: VendorSecureRequestForm.digest_public_token(VendorSecureRequestForm.generate_public_token),
      expires_at: 2.days.from_now, sent_at: 3.days.ago, requested_by: @admin
    )
  end

  def provider_application
    create(:application, :in_progress, medical_provider_name: 'Dr. Provider', medical_provider_email: 'provider@example.com')
  end

  def rejected_income_application
    application = create(:application, :in_progress)
    Current.paper_context = true
    review = create_rejected_proof_review_without_auto_resubmission(
      application: application, admin: @admin, proof_type: :income, rejection_reason: 'Missing income details'
    )
    Current.paper_context = false
    application.income_proof.purge if application.income_proof.attached?
    [application, review]
  end
end
