# frozen_string_literal: true

require 'test_helper'

module Admin
  class SecureRequestFormsTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'show page renders localized secure link channel and status labels' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      create(:secure_request_form, application: application, recipient: application.user, recipient_channel: :sms)

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.channels.sms')
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.statuses.active')
      assert_no_match(/>Sms</, response.body)
    end

    test 'show page hides secure provider information requests when provider info is complete' do
      application = create(:application)
      create(:secure_request_form, application: application, recipient: application.user, recipient_channel: :sms)

      get admin_application_path(application)

      assert_response :success
      assert_no_match(/Secure provider information requests/, response.body)
    end

    test 'show page shows secure provider information requests when any required provider field is missing' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: 'Dr. Secure',
                                         medical_provider_phone: nil,
                                         medical_provider_email: 'secure@example.test')

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.title')
      assert_select "form[action='#{admin_application_secure_request_forms_path(application)}'][data-turbo='false']"
    end

    test 'show page blocks secure provider information request form when managing guardian is ambiguous' do
      dependent = create(:constituent)
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil,
                                         medical_provider_phone: nil,
                                         medical_provider_email: nil)
      create(:guardian_relationship, dependent_user: dependent, guardian_user: create(:constituent))
      create(:guardian_relationship, dependent_user: dependent, guardian_user: create(:constituent))

      get admin_application_path(application)

      assert_response :success
      assert_select 'h3', text: I18n.t('admin.applications.secure_request_forms.managing_guardian.title')
      assert_select 'p', text: I18n.t('admin.applications.secure_request_forms.managing_guardian.description')
      assert_select "form[action='#{admin_application_secure_request_forms_path(application)}']", count: 0
    end

    test 'show page defaults provider info recipient checkbox from resolver for separate dependent email' do
      guardian = create(:constituent, email: "guardian.ui.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.ui.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{dependent.id}'][checked]"
      assert_select "input[name='recipient_ids[]'][value='#{guardian.id}'][checked]", count: 0
      assert_match(/authorized application relationships/, response.body)
    end

    test 'show page defaults provider info recipient checkbox from resolver for guardian email path' do
      guardian = create(:constituent, email: "guardian.ui.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.ui.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{guardian.id}'][checked]"
      assert_select "input[name='recipient_ids[]'][value='#{dependent.id}'][checked]", count: 0
    end

    test 'show page activity history includes secure certification upload requests' do
      application = create(:application,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test')
      create(
        :notification,
        recipient: application.user,
        actor: @admin,
        notifiable: application,
        action: 'cert_upload_requested',
        metadata: {
          'application_id' => application.id,
          'medical_provider_secure_request_form_id' => 501,
          'provider_name' => 'Dr. Secure',
          'provider_email' => 'secure@example.test',
          'requested_channel' => 'email',
          'expires_at' => 2.days.from_now.iso8601
        }
      )

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, 'Certification Upload Request Sent'
      assert_includes response.body, 'Secure certification upload link sent to Dr. Secure'
    end

    test 'show page activity history includes revoked secure certification upload requests' do
      application = create(:application,
                           medical_provider_name: 'Awaiting Provider',
                           medical_provider_email: 'awaiting.provider@example.com')
      Event.create!(
        user: @admin,
        auditable: application,
        action: 'cert_upload_request_revoked',
        metadata: {
          'application_id' => application.id,
          'medical_provider_secure_request_form_id' => 601,
          'provider_name' => 'Awaiting Provider',
          'provider_email' => 'awaiting.provider@example.com',
          'reason' => 'replacement_request'
        }
      )

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, 'Certification Upload Request Revoked'
      assert_includes response.body, 'Secure certification upload link revoked for Awaiting Provider (a***@example.com) before sending a replacement link'
    end

    test 'show page offers secure certification upload link when provider email is present' do
      application = create(:application,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :requested)

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_certification_upload_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Cert Upload Link'
      assert_includes response.body, 'Print DCF'
      assert_not_includes response.body, 'Send Email'
    end

    test 'show page hides secure certification upload link when certification is pending review' do
      application = create(:application,
                           :with_medical_certification,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :received)

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, 'Review Disability Certification'
      assert_not_includes response.body, 'Send Secure Cert Upload Link'
    end

    test 'show page warns before secure certification upload when DocuSeal is active' do
      application = create(:application,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :requested,
                           document_signing_status: :opened)

      get admin_application_path(application)

      assert_response :success
      assert_select 'form[data-turbo="false"][onsubmit*=?]', 'DocuSeal request is already opened'
      assert_select 'form[data-turbo="false"][onsubmit*=?]', 'additional option'
    end

    test 'show page confirms DocuSeal as an additional option when secure certification links are active' do
      application = create(:application,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :requested)
      create(:medical_provider_secure_request_form, application: application)

      get admin_application_path(application)

      assert_response :success
      assert_select 'form[data-turbo-confirm*=?]', 'A secure upload link is already active'
      assert_select 'form[data-turbo-confirm*=?]', 'additional option'
    end

    test 'show page surfaces provider email remediation for secure certification upload' do
      application = create(:application, medical_provider_name: 'Dr. Missing')
      application.update_columns(medical_provider_email: nil, medical_certification_status: :requested)

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, I18n.t('admin.applications.certification_upload_requests.create.provider_email_required')
    end

    test 'show page offers secure proof upload link for rejected unattached income proof' do
      application = create(:application, :in_progress, income_proof_status: :rejected)
      create_rejected_proof_review_without_auto_request(application: application, proof_type: :income, reason: 'Missing income details')
      application.income_proof.purge if application.income_proof.attached?

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Income Upload Link'
    end

    test 'show page offers secure proof upload link for rejected attached income proof' do
      application = create(:application, :in_progress, :with_income_proof, income_proof_status: :rejected)
      create_rejected_proof_review_without_auto_request(application: application, proof_type: :income, reason: 'Missing income details')

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Income Upload Link'
    end

    test 'show page offers secure proof upload link for rejected unattached residency proof' do
      application = create(:application, :in_progress, residency_proof_status: :rejected)
      create_rejected_proof_review_without_auto_request(application: application, proof_type: :residency, reason: 'Missing residency details')
      application.residency_proof.purge if application.residency_proof.attached?

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Residency Upload Link'
    end

    test 'show page offers secure proof upload link for unattached id proof awaiting first submission' do
      application = create(:application, :in_progress, id_proof_status: :not_reviewed)

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Id Upload Link'
    end

    test 'show page offers secure proof upload link for rejected unattached proof without a proof review row' do
      application = create(:application, :in_progress, income_proof_status: :rejected)

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Income Upload Link'
    end

    test 'show page lists issued secure proof upload links in the matching proof sections' do
      application = create(:application, :in_progress,
                           income_proof_status: :not_reviewed,
                           residency_proof_status: :not_reviewed,
                           id_proof_status: :not_reviewed)
      application.income_proof.purge if application.income_proof.attached?
      application.residency_proof.purge if application.residency_proof.attached?
      application.id_proof.purge if application.id_proof.attached?
      income_request = create(:secure_request_form, application: application, recipient: application.user,
                                                    kind: :income_proof_resubmission)
      residency_request = create(:secure_request_form, application: application, recipient: application.user,
                                                       kind: :residency_proof_resubmission)
      id_request = create(:secure_request_form, application: application, recipient: application.user,
                                                kind: :id_proof_resubmission)

      get admin_application_path(application)

      assert_response :success
      assert_select "[data-testid='income-proof-secure-request-forms-panel']"
      assert_select "[data-testid='residency-proof-secure-request-forms-panel']"
      assert_select "[data-testid='id-proof-secure-request-forms-panel']"
      assert_includes response.body, 'Secure income proof upload links'
      assert_includes response.body, 'Secure proof of Maryland residency upload links'
      assert_includes response.body, 'Secure proof of identity upload links'
      assert_select "form[action='#{admin_application_secure_request_form_revocation_path(application, income_request)}']"
      assert_select "form[action='#{admin_application_secure_request_form_revocation_path(application, residency_request)}']"
      assert_select "form[action='#{admin_application_secure_request_form_revocation_path(application, id_request)}']"
      assert_not_includes response.body, 'Send Secure Income Upload Link'
      assert_not_includes response.body, 'Send Secure Residency Upload Link'
      assert_not_includes response.body, 'Send Secure Id Upload Link'
    end

    test 'show page offers secure proof upload link again after issued link expires' do
      application = create(:application, :in_progress, income_proof_status: :not_reviewed)
      application.income_proof.purge if application.income_proof.attached?
      create(:secure_request_form, :expired, application: application,
                                             recipient: application.user,
                                             kind: :income_proof_resubmission)

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Income Upload Link'
    end

    test 'show page does not invent proof submission history for unattached proofs' do
      application = create(:application, :in_progress)
      application.income_proof.purge if application.income_proof.attached?
      application.residency_proof.purge if application.residency_proof.attached?
      application.id_proof.purge if application.id_proof.attached?
      application.update!(
        income_proof_status: :not_reviewed,
        residency_proof_status: :not_reviewed,
        id_proof_status: :not_reviewed
      )

      get admin_application_path(application)

      assert_response :success
      assert_not_includes response.body, '(via application submission)'
    end

    test 'show page surfaces additional DocuSeal certification submissions' do
      application = create(:application, medical_certification_status: :received)
      application.medical_certification.attach(
        io: StringIO.new('secure upload content'),
        filename: 'secure_upload.pdf',
        content_type: 'application/pdf'
      )
      application.additional_medical_certifications.attach(
        io: StringIO.new('docuseal content'),
        filename: 'medical_cert_docuseal_additional_123.pdf',
        content_type: 'application/pdf',
        metadata: { source: 'docuseal' }
      )

      get admin_application_path(application)

      assert_response :success
      assert_select '[data-testid="medical-certification"]', text: /secure_upload\.pdf/
      assert_select '[data-testid="additional-medical-certifications"]', text: /medical_cert_docuseal_additional_123\.pdf/
      assert_select '[data-testid="additional-medical-certifications"]', text: /DocuSeal signed form/
    end

    test 'show page labels additional secure upload certification submissions' do
      application = create(:application, medical_certification_status: :received)
      application.medical_certification.attach(
        io: StringIO.new('docuseal content'),
        filename: 'medical_cert_docuseal_123.pdf',
        content_type: 'application/pdf',
        metadata: { source: 'docuseal' }
      )
      application.additional_medical_certifications.attach(
        io: StringIO.new('secure upload content'),
        filename: 'secure_upload_additional.pdf',
        content_type: 'application/pdf',
        metadata: { source: 'secure_form' }
      )

      get admin_application_path(application)

      assert_response :success
      assert_select '[data-testid="medical-certification"]', text: /medical_cert_docuseal_123\.pdf/
      assert_select '[data-testid="additional-medical-certifications"]', text: /secure_upload_additional\.pdf/
      assert_select '[data-testid="additional-medical-certifications"]', text: /Secure upload/
    end

    test 'secure certification upload request sends mail and redirects with notice' do
      application = create(:application,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :requested)
      result = BaseService::Result.new(success: true, message: 'created', data: {})
      Applications::RequestCertificationUpload.any_instance.expects(:call).returns(result)

      post admin_application_certification_upload_request_path(application)

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('admin.applications.certification_upload_requests.create.success'), flash[:notice]
    end

    test 'secure certification upload request redirects with service failure message' do
      application = create(:application, medical_provider_name: 'Dr. Missing')
      application.update_columns(medical_provider_email: nil, medical_certification_status: :requested)

      post admin_application_certification_upload_request_path(application)

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('applications.certification_upload.messages.provider_email_required'), flash[:alert]
    end

    test 'secure proof resubmission request redirects with service success message' do
      application = create(:application, :in_progress, income_proof_status: :rejected)
      result = BaseService::Result.new(success: true, message: 'Secure proof upload request sent.', data: {})
      service = mock('request-proof-resubmission-service')
      service.expects(:call).returns(result)

      Applications::RequestProofResubmission
        .expects(:new)
        .with do |params|
          params[:application] == application &&
            params[:actor] == @admin &&
            params[:proof_type] == 'income' &&
            params[:recipient_ids].nil?
        end
        .returns(service)

      post admin_application_proof_resubmission_request_path(application), params: { proof_type: :income }

      assert_redirected_to admin_application_path(application)
      assert_equal 'Secure proof upload request sent.', flash[:notice]
    end

    test 'secure proof resubmission request passes selected recipients and channel overrides to service' do
      application = create(:application, :in_progress, income_proof_status: :rejected)
      guardian = create(:constituent)
      result = BaseService::Result.new(success: true, message: 'Secure proof upload request sent.', data: {})
      service = mock('request-proof-resubmission-service')
      service.expects(:call).returns(result)

      Applications::RequestProofResubmission
        .expects(:new)
        .with do |params|
          params[:application] == application &&
            params[:actor] == @admin &&
            params[:proof_type] == 'income' &&
            params[:recipient_ids] == [application.user_id.to_s, guardian.id.to_s] &&
            params[:channel_overrides] == { guardian.id.to_s => 'email' }
        end
        .returns(service)

      post admin_application_proof_resubmission_request_path(application),
           params: {
             proof_type: 'income',
             recipient_ids: [application.user_id, guardian.id],
             channel_overrides: { guardian.id => 'email' }
           }

      assert_redirected_to admin_application_path(application)
      assert_equal 'Secure proof upload request sent.', flash[:notice]
    end

    test 'manual certification upload revoke records an audit event' do
      application = create(:application,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test')
      secure_request_form = create(:medical_provider_secure_request_form,
                                   application: application,
                                   provider_name: 'Dr. Secure',
                                   provider_email: 'secure@example.test')

      assert_difference("Event.where(auditable: application, action: 'cert_upload_request_revoked').count", 1) do
        post admin_application_medical_provider_secure_request_form_revocation_path(application, secure_request_form)
      end

      assert_redirected_to admin_application_path(application)
      event = Event.find_by!(auditable: application, action: 'cert_upload_request_revoked')
      assert_equal secure_request_form.id, event.metadata.fetch('medical_provider_secure_request_form_id')
      assert_equal 'manual_revocation', event.metadata.fetch('reason')
    end

    test 'show page offers batch revoke when active sibling links share a request batch' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      guardian = create(:constituent)
      batch_id = SecureRandom.uuid
      create(:secure_request_form, application: application, recipient: application.user, request_batch_id: batch_id)
      create(:secure_request_form, application: application, recipient: guardian, request_batch_id: batch_id)

      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.table.revoke_batch')
      assert_select 'form[data-turbo="false"][onsubmit*=?]',
                    I18n.t('admin.applications.secure_request_forms.table.revoke_confirm')
      assert_select 'form[data-turbo="false"][onsubmit*=?]',
                    I18n.t('admin.applications.secure_request_forms.table.revoke_batch_confirm')
    end

    test 'batch revoke marks all active sibling links revoked' do
      application = create(:application)
      guardian = create(:constituent)
      batch_id = SecureRandom.uuid
      first_request = create(:secure_request_form, application: application, recipient: application.user,
                                                   request_batch_id: batch_id)
      second_request = create(:secure_request_form, application: application, recipient: guardian,
                                                    request_batch_id: batch_id)

      post admin_application_secure_request_form_batch_revocations_path(application),
           params: { request_batch_id: batch_id }

      assert_redirected_to admin_application_path(application)
      assert_predicate first_request.reload, :status_revoked?
      assert_predicate second_request.reload, :status_revoked?
    end

    test 'batch revoke redirects with alert and rolls back all siblings when one revoke fails' do
      application = create(:application)
      guardian = create(:constituent)
      batch_id = SecureRandom.uuid
      first_request = create(:secure_request_form, application: application, recipient: application.user,
                                                   request_batch_id: batch_id)
      second_request = create(:secure_request_form, application: application, recipient: guardian,
                                                    request_batch_id: batch_id)

      SecureRequestForm.any_instance.stubs(:revoke!).raises(ActiveRecord::StatementInvalid, 'boom')

      post admin_application_secure_request_form_batch_revocations_path(application),
           params: { request_batch_id: batch_id }

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('admin.applications.secure_request_form_batch_revocations.create.failure'), flash[:alert]
      assert_predicate first_request.reload, :status_sent?
      assert_predicate second_request.reload, :status_sent?
    end

    test 'individual revoke redirects with alert when the request is not active' do
      application = create(:application)
      secure_request_form = create(
        :secure_request_form,
        :submitted,
        application: application,
        recipient: application.user
      )

      post admin_application_secure_request_form_revocation_path(application, secure_request_form)

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('admin.applications.secure_request_form_revocations.create.not_active'), flash[:alert]
      assert_predicate secure_request_form.reload, :status_submitted?
    end

    test 'individual revoke redirects with alert when persistence fails' do
      application = create(:application)
      secure_request_form = create(:secure_request_form, application: application, recipient: application.user)
      SecureRequestForm.any_instance.stubs(:revoke!).raises(ActiveRecord::StatementInvalid, 'boom')

      post admin_application_secure_request_form_revocation_path(application, secure_request_form)

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('admin.applications.secure_request_form_revocations.create.failure'), flash[:alert]
      assert_predicate secure_request_form.reload, :status_sent?
    end

    # -----------------------------------------------------------------------
    # Individual revoke: happy path and sibling independence
    # -----------------------------------------------------------------------

    test 'individual revoke marks the targeted form revoked and redirects with success notice' do
      application = create(:application)
      secure_request_form = create(:secure_request_form, application: application, recipient: application.user)

      post admin_application_secure_request_form_revocation_path(application, secure_request_form)

      assert_redirected_to admin_application_path(application)
      assert_predicate secure_request_form.reload, :status_revoked?
    end

    test 'individual revoke marks a proof secure request form revoked and records an audit event' do
      application = create(:application)
      secure_request_form = create(:secure_request_form, application: application, recipient: application.user,
                                                         kind: :income_proof_resubmission)

      assert_difference -> { Event.where(auditable: application, action: 'proof_resubmission_request_revoked').count }, 1 do
        post admin_application_secure_request_form_revocation_path(application, secure_request_form)
      end

      assert_redirected_to admin_application_path(application)
      assert_predicate secure_request_form.reload, :status_revoked?
    end

    test 'revoking one secure request form does not revoke sibling forms from the same batch' do
      application = create(:application)
      guardian = create(:constituent)
      batch_id = SecureRandom.uuid
      target_form = create(:secure_request_form, application: application,
                                                 recipient: application.user,
                                                 request_batch_id: batch_id)
      sibling_form = create(:secure_request_form, application: application,
                                                  recipient: guardian,
                                                  request_batch_id: batch_id)

      post admin_application_secure_request_form_revocation_path(application, target_form)

      assert_predicate target_form.reload, :status_revoked?
      assert_not_predicate sibling_form.reload, :status_revoked?,
                           'Revoking one recipient link must not revoke sibling links in the same batch'
    end

    private

    def create_rejected_proof_review_without_auto_request(application:, proof_type:, reason:)
      original_paper_context = Current.paper_context
      Current.paper_context = true

      create(:proof_review,
             application: application,
             admin: @admin,
             proof_type: proof_type,
             status: :rejected,
             rejection_reason: reason)
    ensure
      Current.paper_context = original_paper_context
    end
  end
end
