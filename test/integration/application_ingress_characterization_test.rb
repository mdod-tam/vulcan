# frozen_string_literal: true

require 'test_helper'
require 'open-uri'
require 'support/action_mailbox_test_helper'

class ApplicationIngressCharacterizationTest < ActionDispatch::IntegrationTest
  include ActionDispatch::TestProcess::FixtureFile
  include ActionMailboxTestHelper
  include MailboxTestHelper

  setup do
    @admin = create(:admin)
    @system_user = create(:admin, email: generate(:email))
    @webhook_secret = 'test_webhook_secret'

    User.stubs(:system_user).returns(@system_user)
    Rails.application.credentials.stubs(:webhook_secret).returns(@webhook_secret)
    ApplicationController.any_instance.stubs(:authenticate_user!).returns(true)
    ProofAttachmentValidator.stubs(:validate!).returns(true)

    proof_rate_limit_policy.value = 5
    proof_rate_limit_policy.updated_by = @admin
    proof_rate_limit_policy.save!

    proof_period_policy.value = 1
    proof_period_policy.updated_by = @admin
    proof_period_policy.save!

    max_rejections_policy.value = 10
    max_rejections_policy.updated_by = @admin
    max_rejections_policy.save!

    proof_email_rate_limit_policy.value = 100
    proof_email_rate_limit_policy.updated_by = @admin
    proof_email_rate_limit_policy.save!

    setup_fpl_policies
  end

  test 'portal proof upload produces the expected proof state' do
    constituent = create(:constituent)
    application = create(:application, :paper_rejected_proofs, user: constituent)

    sign_in_for_integration_test(constituent)

    post "/constituent_portal/applications/#{application.id}/proofs/resubmit",
         params: {
           proof_type: 'income',
           income_proof_upload: fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf')
         }

    assert_redirected_to constituent_portal_application_path(application)

    assert_proof_contract(
      application,
      proof_type: 'income',
      expected_status: 'not_reviewed',
      expected_submission_method: 'web',
      expected_actor: constituent,
      expected_event_action: 'income_proof_attached'
    )

    # CHARACTERIZATION: needs_review_since is set by ProofAttachmentService.update_application_status
    # via update_columns when status is :not_reviewed. The concern's set_needs_review_timestamp
    # callback does NOT fire (guarded by Current.proof_attachment_service_context).
    application.reload
    refute_nil application.needs_review_since, 'needs_review_since should be set for not_reviewed proof'
  end

  test 'scanned proof upload produces the expected proof state' do
    application = create(:application, user: create(:constituent))

    sign_in_for_integration_test(@admin)

    post admin_application_scanned_proofs_path(application),
         params: {
           proof_type: 'income',
           file: fixture_file_upload(Rails.root.join('test/fixtures/files/test_proof.pdf'), 'application/pdf')
         }

    assert_redirected_to admin_application_path(application)

    assert_proof_contract(
      application,
      proof_type: 'income',
      expected_status: 'approved',
      expected_submission_method: 'paper',
      expected_actor: @admin,
      expected_event_action: 'proof_submitted'
    )

    # CHARACTERIZATION: needs_review_since is NOT set for scanned proofs because
    # ProofAttachmentService only sets it when status is :not_reviewed, and the
    # scanned controller passes status: :approved.
    application.reload
    assert_nil application.needs_review_since, 'needs_review_since should not be set for approved scanned proof'
  end

  # CHARACTERIZATION: ProofAttachmentService skips constituent notification when
  # Current.paper_context is true (paper/scanned paths set this). The scanned proof
  # controller sends its own ApplicationNotificationsMailer.proof_received instead.
  # The concern's notify_admins_of_new_proofs callback does NOT fire from any
  # ProofAttachmentService path because update_columns bypasses after_save.
  test 'scanned proof upload does not send constituent notification via NotificationService' do
    constituent = create(:constituent)
    application = create(:application, user: constituent)

    sign_in_for_integration_test(@admin)

    assert_no_difference -> { Notification.where(notifiable: application, action: 'income_proof_attached').count } do
      post admin_application_scanned_proofs_path(application),
           params: {
             proof_type: 'income',
             file: fixture_file_upload(Rails.root.join('test/fixtures/files/test_proof.pdf'), 'application/pdf')
           }
    end
  end

  test 'paper application creation produces approved paper proof state' do
    constituent = create(:constituent)

    service = Applications::PaperApplicationService.new(
      params: {
        existing_constituent_id: constituent.id,
        contact_info_verified: '1',
        application: {
          household_size: 1,
          annual_income: 12_000,
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_name: 'Dr. Paper',
          medical_provider_phone: '555-111-2222',
          medical_provider_email: 'paper-doctor@example.com'
        },
        income_proof_action: 'accept',
        income_proof: fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf'),
        residency_proof_action: 'accept',
        residency_proof: fixture_file_upload(Rails.root.join('test/fixtures/files/test_residency_proof.pdf'), 'application/pdf'),
        medical_certification_action: 'approved',
        medical_certification: fixture_file_upload(Rails.root.join('test/fixtures/files/test_document.pdf'), 'application/pdf')
      },
      admin: @admin
    )

    assert service.create, "Expected paper application creation to succeed, got: #{service.errors.inspect}"

    application = service.application
    refute_nil application
    assert_equal 'paper', application.submission_method
    assert_equal 'approved', application.income_proof_status
    assert_equal 'approved', application.residency_proof_status
    assert_equal 'approved', application.medical_certification_status
    assert application.income_proof.attached?
    assert application.residency_proof.attached?
    assert application.medical_certification.attached?
    assert Event.where(auditable: application, action: 'application_created').exists?
  end

  test 'proof mailbox produces the expected proof state' do
    constituent = create(:constituent)
    application = create(:application, user: constituent, status: :in_progress)

    inbound_email = receive_inbound_email_from_mail(
      to: 'proof@mdmat.org',
      from: constituent.email,
      subject: 'Income Proof Submission',
      body: 'Attached income proof.'
    ) do |mail|
      mail.attachments['income-proof.pdf'] = 'Income proof attachment ' * 80
    end

    assert_equal ProofSubmissionMailbox, ApplicationMailbox.mailbox_for(inbound_email)

    assert_proof_contract(
      application,
      proof_type: 'income',
      expected_status: 'not_reviewed',
      expected_submission_method: 'email',
      expected_actor: constituent,
      expected_event_action: 'income_proof_submitted'
    )
  end

  test 'admin certification review produces the expected certification state' do
    application = create(:application, medical_certification_status: :requested)

    sign_in_for_integration_test(@admin)

    patch upload_medical_certification_admin_application_path(application),
          params: {
            medical_certification: fixture_file_upload(Rails.root.join('test/fixtures/files/test_document.pdf'), 'application/pdf'),
            medical_certification_status: 'approved'
          }

    assert_redirected_to admin_application_path(application)

    assert_medical_certification_contract(
      application,
      expected_status: 'approved',
      expected_from_status: 'requested',
      expected_event_action: 'medical_certification_status_changed',
      expected_submission_method: 'admin_upload',
      expected_actor: @admin
    )
  end

  test 'docuseal completion produces the expected certification state' do
    application = create(
      :application,
      document_signing_service: 'docuseal',
      document_signing_submission_id: 'sub_123456',
      document_signing_status: :sent,
      medical_certification_status: :requested
    )

    response = mock('docuseal_response')
    status = mock('docuseal_status')
    status.stubs(:success?).returns(true)
    response.stubs(:status).returns(status)
    response.stubs(:body).returns('signed pdf')
    HTTP.stubs(:timeout).with(30).returns(HTTP)
    HTTP.stubs(:get).with('https://example.com/signed_doc.pdf').returns(response)

    payload = {
      event_type: 'form.completed',
      data: {
        'submission_id' => 'sub_123456',
        'email' => 'doctor@example.com',
        'documents' => [{ 'url' => 'https://example.com/signed_doc.pdf' }],
        'audit_log_url' => 'https://example.com/audit_log'
      }
    }

    post webhooks_docuseal_medical_certification_path,
         params: payload,
         headers: webhook_headers(payload),
         as: :json

    assert_response :ok

    application.reload
    assert application.medical_certification.attached?
    assert_equal 'received', application.medical_certification_status
    assert_equal 'signed', application.document_signing_status
    assert_equal 'https://example.com/audit_log', application.document_signing_audit_url
    assert Event.where(auditable: application, action: 'document_signing_completed').exists?
  end

  test 'certification mailbox produces the expected certification state' do
    with_committed_records do
      medical_provider = create(:medical_provider)
      application = create(
        :application,
        status: :awaiting_dcf,
        medical_provider_name: medical_provider.full_name,
        medical_provider_email: medical_provider.email,
        medical_provider_phone: medical_provider.phone,
        medical_certification_status: :requested
      )

      mail = Mail.new do
        to 'disability_cert@mdmat.org'
        from medical_provider.email
        subject "Medical Certification for Application ##{application.id}"

        text_part do
          body "Attached certification for Application ##{application.id}"
        end

        add_file(
          filename: 'medical-certification.pdf',
          content: 'certification pdf ' * 80,
          content_type: 'application/pdf'
        )
      end

      inbound_email = ActionMailbox::InboundEmail.create_and_extract_message_id!(mail.to_s)
      inbound_email.route

      assert_equal MedicalCertificationMailbox, ApplicationMailbox.mailbox_for(inbound_email)

      assert_medical_certification_contract(
        application,
        expected_status: 'received',
        expected_from_status: 'requested',
        expected_event_action: 'medical_certification_received',
        expected_submission_method: 'email',
        expected_actor: @system_user
      )
    end
  end

  test 'direct certification webhook produces the expected certification state' do
    application = create(
      :application,
      status: :awaiting_dcf,
      medical_provider_email: 'doctor@example.com',
      medical_certification_status: :requested
    )

    # URI.open is private in Ruby 3.4+; stub the controller's download at the Kernel level
    # since open-uri patches Kernel#open
    OpenURI.stubs(:open_uri).returns(StringIO.new('certification pdf'))

    payload = {
      provider_email: 'doctor@example.com',
      provider_name: 'Dr. Example',
      constituent_name: application.user.full_name,
      document_url: 'https://example.com/certification.pdf',
      original_filename: 'certification.pdf',
      webhook_id: SecureRandom.uuid
    }

    post webhooks_medical_certifications_path,
         params: payload,
         headers: webhook_headers(payload),
         as: :json

    assert_response :ok

    assert_medical_certification_contract(
      application,
      expected_status: 'received',
      expected_from_status: 'requested',
      expected_event_action: 'medical_certification_received',
      expected_submission_method: 'webhook',
      expected_actor: @system_user
    )
  end

  private

  def proof_rate_limit_policy
    @proof_rate_limit_policy ||= Policy.find_or_initialize_by(key: 'proof_submission_rate_limit_web')
  end

  def proof_period_policy
    @proof_period_policy ||= Policy.find_or_initialize_by(key: 'proof_submission_rate_period')
  end

  def max_rejections_policy
    @max_rejections_policy ||= Policy.find_or_initialize_by(key: 'max_proof_rejections')
  end

  def proof_email_rate_limit_policy
    @proof_email_rate_limit_policy ||= Policy.find_or_initialize_by(key: 'proof_submission_rate_limit_email')
  end

  def assert_proof_contract(application, proof_type:, expected_status:, expected_submission_method:, expected_actor:,
                            expected_event_action:)
    application.reload

    assert application.public_send("#{proof_type}_proof").attached?
    assert_equal expected_status, application.public_send("#{proof_type}_proof_status")

    event = Event.where(auditable: application, action: expected_event_action)
                 .order(:created_at)
                 .last

    refute_nil event
    assert_equal expected_actor, event.user
    assert_equal proof_type.to_s, event.metadata['proof_type']
    assert_equal expected_submission_method, event.metadata['submission_method']
  end

  def assert_medical_certification_contract(application, expected_status:, expected_from_status:, expected_event_action:,
                                            expected_submission_method:, expected_actor:)
    application.reload

    assert application.medical_certification.attached?
    assert_equal expected_status, application.medical_certification_status

    status_change = ApplicationStatusChange.where(application: application, change_type: :medical_certification)
                                           .order(:created_at)
                                           .last
    refute_nil status_change
    assert_equal expected_from_status, status_change.from_status
    assert_equal expected_status, status_change.to_status
    assert_equal 'medical_certification', status_change.metadata['change_type']
    assert_equal expected_submission_method, status_change.metadata['submission_method']

    event = Event.where(auditable: application, action: expected_event_action).order(:created_at).last
    refute_nil event
    assert_equal expected_actor, event.user
    assert_equal expected_submission_method, event.metadata['submission_method'] if event.metadata.key?('submission_method')
  end

  def webhook_headers(payload)
    {
      'Content-Type' => 'application/json',
      'X-Webhook-Signature' => OpenSSL::HMAC.hexdigest('sha256', @webhook_secret, payload.to_json)
    }
  end

  def with_committed_records
    DatabaseCleaner.strategy = :truncation
    DatabaseCleaner.clean
    Current.reset
    @system_user = create(:admin, email: generate(:email))
    User.stubs(:system_user).returns(@system_user)
    yield
  ensure
    Current.reset
    DatabaseCleaner.strategy = :transaction
  end
end
