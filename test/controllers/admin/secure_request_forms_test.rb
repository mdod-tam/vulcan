# frozen_string_literal: true

require 'test_helper'

module Admin
  class SecureRequestFormsTest < ActionDispatch::IntegrationTest
    include ProofResubmissionTestHelper

    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
    end

    test 'proof chooser exposes explicit SMS with provider information already complete' do
      recipient = build_sms_only_constituent
      application = create(:application, :in_progress, user: recipient)

      get admin_application_path(application)

      assert_response :success
      %w[income residency id].each do |proof_type|
        assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}']" do
          assert_select "input[name='proof_type'][value='#{proof_type}']"
        end
        assert_select "#proof_#{proof_type}_channel_#{recipient.id} option[value='sms']"
        assert_select "#proof_#{proof_type}_channel_#{recipient.id} option[value='']"
        assert_select "#proof_#{proof_type}_recipient_#{recipient.id}[checked]", count: 0
      end
    end

    test 'Turbo proof rejection preserves recipient controls in every proof section' do
      recipient = build_sms_only_constituent
      application = create(:application, :in_progress, :with_income_proof, user: recipient)

      patch update_proof_status_admin_application_path(application),
            params: { proof_type: 'income', status: 'rejected', rejection_reason: 'Unreadable document' },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type
      assert_predicate application.reload, :income_proof_status_rejected?
      assert_empty application.secure_request_forms
      assert_select "turbo-stream[target='attachments-section'] template" do
        %w[income residency id].each do |proof_type|
          assert_select "#proof_#{proof_type}_request_chooser" do
            assert_select "#proof_#{proof_type}_recipient_#{recipient.id}:not([disabled])"
            assert_select "#proof_#{proof_type}_channel_#{recipient.id} option[value='sms']"
          end
        end
      end
    end

    test 'provider channel options describe their own destination and stable owner identity' do
      application = create(:application, status: :awaiting_proof, medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      recipient = application.user
      recipient.update!(phone_type: 'text')

      get admin_application_path(application)

      assert_select "#provider_info_channel_#{recipient.id} option[value='letter']", text: /#{Regexp.escape(recipient.physical_address_1)}/
      assert_select "#provider_info_channel_#{recipient.id} option[value='sms']", text: /SMS.*#{recipient.phone.last(4)}/
      assert_select "label[for='provider_info_recipient_#{recipient.id}']", text: /ID: #{recipient.id}/
      assert_select "#provider_info_recipient_#{recipient.id}_destination", count: 0
    end

    test 'staff can send every proof type explicitly by SMS with provider data complete' do
      recipient = build_sms_only_constituent
      application = create(:application, :in_progress, user: recipient)
      SmsService.expects(:send_message).with(recipient.phone, anything, sensitive: true, context: anything).times(3).returns(true)

      %w[income residency id].each do |proof_type|
        assert_difference('SecureRequestForm.count', 1) do
          post admin_application_proof_resubmission_request_path(application),
               params: { proof_type: proof_type, recipient_ids: [recipient.id],
                         channel_overrides: { recipient.id => 'sms' } }
        end
        assert_redirected_to admin_application_path(application)
        form = application.secure_request_forms.order(:created_at).last
        assert_equal "#{proof_type}_proof_resubmission", form.kind
        assert_equal recipient.id, form.delivery_owner_id
        assert_predicate form, :recipient_channel_sms?
        assert_predicate form, :active?
      end
    end

    test 'proof chooser empty and forged selections create no requests' do
      application = create(:application, :in_progress)
      outsider = create(:constituent)
      [[], [''], [outsider.id]].each do |ids|
        assert_no_difference(['SecureRequestForm.count', 'Notification.count']) do
          post admin_application_proof_resubmission_request_path(application),
               params: { proof_type: 'id', recipient_ids: ids,
                         channel_overrides: { outsider.id => 'email' } }
        end
        assert_redirected_to admin_application_path(application)
        assert flash[:alert].present?
      end
    end

    test 'partial proof recovery offers revoked recipients while preserving successful active links' do
      recipient = build_sms_only_constituent
      application = create(:application, :in_progress, user: recipient)
      guardian = create(:constituent, phone_type: 'text')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: recipient, relationship_type: 'Parent')
      pending_guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: pending_guardian, dependent_user: recipient, relationship_type: 'Parent')
      application.update!(managing_guardian: guardian)
      batch = SecureRandom.uuid
      create(:secure_request_form, :revoked, application: application, recipient: pending_guardian,
                                             kind: :id_proof_resubmission, request_batch_id: batch)
      active = create(:secure_request_form, application: application, recipient: guardian,
                                            kind: :id_proof_resubmission, request_batch_id: batch,
                                            recipient_role: :guardian, recipient_relationship_type: 'Parent',
                                            delivery_owner: guardian)
      create(:secure_request_form, :revoked, application: application, recipient: recipient,
                                             kind: :id_proof_resubmission, request_batch_id: batch)

      get admin_application_path(application)

      assert_select '#proof_id_request_chooser' do
        assert_select "#proof_id_recipient_#{recipient.id}"
        assert_select "#proof_id_recipient_#{guardian.id}", count: 0
      end
      assert_select "[data-testid='id-proof-secure-request-forms-panel'] a[href='#{admin_user_path(guardian)}']", text: /Guardian.*Parent.*ID: #{guardian.id}/
      SmsService.expects(:send_message).returns(true)
      assert_difference('SecureRequestForm.count', 1) do
        post admin_application_proof_resubmission_request_path(application),
             params: { proof_type: 'id', recipient_ids: [recipient.id],
                       channel_overrides: { recipient.id => 'sms' } }
      end
      assert_predicate active.reload, :active?
      get admin_application_path(application)
      assert_select '#proof_id_request_chooser' do
        assert_select "#proof_id_recipient_#{pending_guardian.id}"
        assert_select "#proof_id_recipient_#{recipient.id}", count: 0
        assert_select "#proof_id_recipient_#{guardian.id}", count: 0
      end
    end

    private

    # Paper context permits no email. Direct updates bypass address validation to model incomplete legacy records.
    def build_sms_only_constituent
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: "555-#{rand(200..899)}-#{rand(1000..9999)}",
                                  phone_type: 'text', communication_preference: 'letter')
      Current.paper_context = false
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      user
    ensure
      Current.reset
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

    test 'show page hides secure certification upload link when certification is attached before request' do
      application = create(:application,
                           :with_medical_certification,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :not_requested)

      get admin_application_path(application)

      assert_response :success
      assert_select '[data-testid="medical-certification"]', text: /medical_certification\.pdf/
      assert_not_includes response.body, 'Send Secure Cert Upload Link'
    end

    test 'show page offers secure certification upload link after attached certification is rejected' do
      application = create(:application,
                           :with_medical_certification,
                           medical_provider_name: 'Dr. Secure',
                           medical_provider_email: 'secure@example.test',
                           medical_certification_status: :rejected)

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_certification_upload_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Cert Upload Link'
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
      create_rejected_proof_review_without_auto_resubmission(application: application, admin: @admin, proof_type: :income, rejection_reason: 'Missing income details')
      application.income_proof.purge if application.income_proof.attached?

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Income Upload Link'
    end

    test 'show page offers secure proof upload link for rejected attached income proof' do
      application = create(:application, :in_progress, :with_income_proof, income_proof_status: :rejected)
      create_rejected_proof_review_without_auto_resubmission(application: application, admin: @admin, proof_type: :income, rejection_reason: 'Missing income details')

      get admin_application_path(application)

      assert_response :success
      assert_select "form[action='#{admin_application_proof_resubmission_request_path(application)}'][data-turbo='false']"
      assert_includes response.body, 'Send Secure Income Upload Link'
    end

    test 'show page offers secure proof upload link for rejected unattached residency proof' do
      application = create(:application, :in_progress, residency_proof_status: :rejected)
      create_rejected_proof_review_without_auto_resubmission(application: application, admin: @admin, proof_type: :residency, rejection_reason: 'Missing residency details')
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

    test 'show page channel select lists only currently available channels and defaults to the resolved channel' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      application.user.update!(phone_type: 'text')

      get admin_application_path(application)

      assert_response :success
      assert_select "select#provider_info_channel_#{application.user.id}" do
        assert_select "option[value='email'][selected]"
        assert_select "option[value='sms']"
        assert_select "option[value='letter']"
        assert_select 'option', count: 3
      end
    end

    test 'show page channel select omits sms for a voice phone recipient' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      application.user.update!(phone_type: 'voice')

      get admin_application_path(application)

      assert_response :success
      assert_select "select#provider_info_channel_#{application.user.id}" do
        assert_select "option[value='email'][selected]"
        assert_select "option[value='letter']"
        assert_select "option[value='sms']", count: 0
      end
    end

    test 'show page disables a no-route recipient and explains why' do
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      Current.paper_context = false
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{user.id}'][disabled]"
      assert_select "select[name='channel_overrides[#{user.id}]']", count: 0
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.no_route')
    end

    test 'forged sms channel override is rejected without creating a secure request form' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      application.user.update!(phone_type: 'voice')

      assert_no_difference('SecureRequestForm.count') do
        post admin_application_secure_request_forms_path(application),
             params: {
               recipient_ids: [application.user_id],
               channel_overrides: { application.user_id => 'sms' }
             }
      end

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('applications.provider_info.messages.invalid_channel_override',
                          locale: @admin.effective_locale),
                   flash[:alert]
    end

    test 'unknown forged channel value is rejected without creating a secure request form' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      assert_no_difference('SecureRequestForm.count') do
        post admin_application_secure_request_forms_path(application),
             params: {
               recipient_ids: [application.user_id],
               channel_overrides: { application.user_id => 'carrier_pigeon' }
             }
      end

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('applications.provider_info.messages.invalid_channel_override',
                          locale: @admin.effective_locale),
                   flash[:alert]
    end

    test 'resend forms carry no stale hidden channel override fields' do
      application = create(:application, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      create(:secure_request_form, application: application, recipient: application.user)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[type='hidden'][name^='channel_overrides']", count: 0
    end

    test 'show page enables an sms-only recipient behind an explicit channel prompt' do
      user = build_sms_only_constituent
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      assert_select "form[data-controller='final-submit-gate']"
      assert_select "fieldset[data-requires-one-checkbox='true']"
      assert_select "input[name='recipient_ids[]'][value='#{user.id}']:not([disabled])"
      assert_select "input[name='recipient_ids[]'][value='#{user.id}'][checked]", count: 0
      # Native required validation would block other selected recipients.
      # The server rejects a selected SMS-only row with no channel.
      assert_select "select[name='channel_overrides[#{user.id}]']" do
        assert_select "option[value='']",
                      text: I18n.t('admin.applications.secure_request_forms.panel.channel_prompt')
        assert_select "option[value='sms']"
        assert_select "option[value='sms'][selected]", count: 0
        assert_select "option[value='email']", count: 0
        assert_select "option[value='letter']", count: 0
      end
      assert_select "select[name='channel_overrides[#{user.id}]'][required]", count: 0
      assert_select "input[type='submit'][disabled][data-final-submit-gate-target='submitButton']"
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.selection_help')
      assert_not_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.no_route')
    end

    test 'channel select labels name their recipient for assistive technology' do
      user = build_sms_only_constituent
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      recipient_label = "#{user.full_name} (#{I18n.t('admin.applications.secure_request_forms.roles.applicant')}) (ID: #{user.id})"
      assert_select "label[for='provider_info_channel_#{user.id}']",
                    text: I18n.t('admin.applications.secure_request_forms.panel.channel_label',
                                 recipient: recipient_label)
    end

    test 'same-name guardian and applicant rows are disambiguated by role and relationship' do
      dependent = create(:constituent, first_name: 'Casey', last_name: 'Example')
      guardian = create(:constituent, first_name: 'Casey', last_name: 'Example')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      create(:secure_request_form, application: application, recipient: guardian,
                                   recipient_role: :guardian, recipient_relationship_type: 'Parent')

      get admin_application_path(application)

      assert_response :success
      applicant_label = "Casey Example (#{I18n.t('admin.applications.secure_request_forms.roles.applicant')}) (ID: #{dependent.id})"
      guardian_label =
        "Casey Example (#{I18n.t('admin.applications.secure_request_forms.roles.guardian')} — Parent) (ID: #{guardian.id})"
      assert_select "label[for='provider_info_recipient_#{dependent.id}']", text: applicant_label
      assert_select "label[for='provider_info_recipient_#{guardian.id}']", text: guardian_label
      assert_select "label[for='provider_info_channel_#{guardian.id}']",
                    text: I18n.t('admin.applications.secure_request_forms.panel.channel_label',
                                 recipient: guardian_label)
      assert_select 'td', text: /#{Regexp.escape(guardian_label)}/
    end

    test 'mixed recipients submit when the unchecked sms-only recipient stays on the prompt' do
      sms_only = build_sms_only_constituent
      guardian = create(:constituent)
      # A blank guardian address removes the letter route.
      # The later relationship avoids automatic guardian selection and its email route.
      guardian.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: sms_only, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: sms_only,
                                     relationship_type: 'Parent')

      # An unchecked SMS-only row must not block the selected guardian.
      assert_difference('SecureRequestForm.count', 1) do
        post admin_application_secure_request_forms_path(application),
             params: {
               recipient_ids: [guardian.id],
               channel_overrides: { guardian.id => '', sms_only.id => '' }
             }
      end

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('admin.applications.secure_request_forms.create.success'), flash[:notice]
      form = application.secure_request_forms.order(:created_at).last
      assert_equal guardian.id, form.recipient_id
    end

    test 'ineligible guardian recipient is disabled with an explanation, not offered' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      guardian.update!(status: :suspended)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{guardian.id}'][disabled]"
      assert_select "select[name='channel_overrides[#{guardian.id}]']", count: 0
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.ineligible')
      # Both dependent routes belong to the suspended guardian.
      assert_select "input[name='recipient_ids[]'][value='#{dependent.id}'][disabled]"
      assert_select "select[name='channel_overrides[#{dependent.id}]']", count: 0
      # Apostrophe-free substring: ERB HTML-escapes the copy's apostrophe.
      assert_includes response.body, 'A delivery route exists, but the contact or address on file belongs to'
    end

    test 'submit is disabled when no recipient is selectable' do
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      Current.paper_context = false
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{user.id}'][disabled]"
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.no_route')
      assert_select "input[type='submit'][disabled][value=?]",
                    I18n.t('admin.applications.secure_request_forms.panel.submit')
    end

    test 'panel copy has complete spanish translations' do
      I18n.with_locale(:es) do
        assert_equal 'Canal de entrega para Ana Ejemplo',
                     I18n.t('admin.applications.secure_request_forms.panel.channel_label', recipient: 'Ana Ejemplo')
        assert_equal 'Seleccione un canal', I18n.t('admin.applications.secure_request_forms.panel.channel_prompt')
        assert_equal 'Este registro ya no puede recibir solicitudes seguras.',
                     I18n.t('admin.applications.secure_request_forms.panel.ineligible')
        assert_match(/^No hay un canal de entrega/,
                     I18n.t('admin.applications.secure_request_forms.panel.no_route'))
        assert_match(/^Existe un canal de entrega/,
                     I18n.t('admin.applications.secure_request_forms.panel.owner_ineligible'))
        assert_equal 'Destinatarios', I18n.t('admin.applications.secure_request_forms.panel.legend')
        assert_match(/^Ningún destinatario/,
                     I18n.t('admin.applications.secure_request_forms.panel.submit_blocked'))
        assert_match(/^Seleccione al menos un destinatario/,
                     I18n.t('admin.applications.secure_request_forms.panel.selection_help'))
        assert_equal 'Solicitante', I18n.t('admin.applications.secure_request_forms.roles.applicant')
        assert_equal 'Tutor', I18n.t('admin.applications.secure_request_forms.roles.guardian')
        assert_equal 'Se entrega a a***@example.com',
                     I18n.t('admin.applications.secure_request_forms.panel.destination',
                            destination: 'a***@example.com')
        assert_equal 'Se entrega a Ana Ejemplo — a***@example.com',
                     I18n.t('admin.applications.secure_request_forms.panel.destination_via',
                            owner: 'Ana Ejemplo', destination: 'a***@example.com')
        assert_match(/^Entregado originalmente a Ana Ejemplo/,
                     I18n.t('admin.applications.secure_request_forms.table.originally_delivered_to',
                            owner: 'Ana Ejemplo'))
        assert_equal 'Correo postal: 1 Calle Mayor, Baltimore, MD 21201',
                     I18n.t('admin.applications.secure_request_forms.contact.letter_with_address',
                            address: '1 Calle Mayor, Baltimore, MD 21201')
      end
    end

    test 'explicitly selecting sms for an sms-only recipient issues the secure request' do
      user = build_sms_only_constituent
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      SmsService.stubs(:send_message).returns(true)

      assert_difference('SecureRequestForm.count', 1) do
        post admin_application_secure_request_forms_path(application),
             params: {
               recipient_ids: [user.id],
               channel_overrides: { user.id => 'sms' }
             }
      end

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('admin.applications.secure_request_forms.create.success'), flash[:notice]
      form = application.secure_request_forms.order(:created_at).last
      assert_equal user.id, form.recipient_id
      assert_predicate form, :recipient_channel_sms?
    end

    test 'sms-only recipient left on the channel prompt fails closed without creating a form' do
      user = build_sms_only_constituent
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)
      SmsService.expects(:send_message).never

      # A blank override permits defaults, but SMS is never a default.
      assert_no_difference('SecureRequestForm.count') do
        post admin_application_secure_request_forms_path(application),
             params: {
               recipient_ids: [user.id],
               channel_overrides: { user.id => '' }
             }
      end

      assert_redirected_to admin_application_path(application)
      assert_equal I18n.t('applications.provider_info.messages.no_contact_path',
                          locale: @admin.effective_locale),
                   flash[:alert]
    end

    test 'show page explains owner-ineligible routes instead of offering channels issuance rejects' do
      # The dependent is eligible, but its only contact and address belong to the suspended guardian.
      guardian = create(:constituent, email: "guardian.owner.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.owner.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)
      guardian.update!(status: :suspended)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{dependent.id}'][disabled]"
      assert_select "select[name='channel_overrides[#{dependent.id}]']", count: 0
      # ERB escapes the apostrophe, so this assertion uses the prefix.
      assert_includes response.body, 'A delivery route exists, but the contact or address on file belongs to'
      assert_not_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.no_route')
    end

    test 'show page omits owner-ineligible channels from the select while keeping eligible ones' do
      # Only the letter route belongs to the suspended guardian.
      guardian = create(:constituent, physical_address_1: '9 Guardian Way')
      dependent_email = "dependent.mixed.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)
      guardian.update!(status: :suspended)

      get admin_application_path(application)

      assert_response :success
      assert_select "input[name='recipient_ids[]'][value='#{dependent.id}']:not([disabled])"
      assert_select "select[name='channel_overrides[#{dependent.id}]'] option[value='email']"
      assert_select "select[name='channel_overrides[#{dependent.id}]'] option[value='letter']", count: 0
    end

    test 'recipient fieldset has a short legend and disabled rows link their explanation' do
      Current.paper_context = true
      user = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      Current.paper_context = false
      user.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: user, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil)

      get admin_application_path(application)

      assert_response :success
      assert_select 'fieldset legend', I18n.t('admin.applications.secure_request_forms.panel.legend')
      assert_select "input[name='recipient_ids[]'][value='#{user.id}'][disabled]" \
                    "[aria-describedby='provider_info_recipient_#{user.id}_unavailable']"
      assert_select "p#provider_info_recipient_#{user.id}_unavailable"
      assert_select "input[type='submit'][disabled][aria-disabled='true']" \
                    "[aria-describedby='provider_info_submit_blocker']"
      assert_includes response.body, I18n.t('admin.applications.secure_request_forms.panel.submit_blocked')
    end

    test 'notification detail names the guardian delivery owner for guardian-routed deliveries' do
      guardian = create(:constituent, email: "guardian.note.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.note.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)

      post admin_application_secure_request_forms_path(application),
           params: { recipient_ids: [dependent.id] }

      assert_redirected_to admin_application_path(application)
      get admin_application_path(application)

      assert_response :success
      assert_includes response.body, "(delivered to #{guardian.full_name} (Guardian) (ID: #{guardian.id}))"
    end

    test 'issued link rows label a differing delivery owner as original and keep resend honest' do
      guardian = create(:constituent, email: "guardian.orig.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.orig.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)

      post admin_application_secure_request_forms_path(application),
           params: { recipient_ids: [dependent.id] }

      assert_redirected_to admin_application_path(application)
      get admin_application_path(application)

      assert_response :success
      dependent_label = "#{dependent.full_name} (#{I18n.t('admin.applications.secure_request_forms.roles.applicant')})"
      owner_line = I18n.t('admin.applications.secure_request_forms.table.originally_delivered_to',
                          owner: "#{guardian.full_name} (#{I18n.t('admin.applications.secure_request_forms.roles.guardian')}) (ID: #{guardian.id})")
      assert_select 'td', text: /#{Regexp.escape(dependent_label)}/
      assert_select 'td span', text: /#{Regexp.escape(owner_line)}/
      assert_includes owner_line, 'Resending re-checks'
    end

    test 'issued letter rows avoid claiming a historical address' do
      guardian = create(:constituent, physical_address_1: '9 Guardian Way')
      dependent = create(:constituent, email: "dependent.ltr.#{SecureRandom.hex(3)}@system.matvulcan.local",
                                       dependent_email: guardian.email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)
      create(:secure_request_form, application: application, recipient: dependent,
                                   recipient_channel: :letter, recipient_role: :constituent,
                                   recipient_email: nil, recipient_phone: nil,
                                   delivery_owner: guardian, delivery_source: 'managing_guardian')

      get admin_application_path(application)

      assert_response :success
      assert_select 'td', text: 'Postal mail'
      assert_select 'td', text: /9 Guardian Way/, count: 0
    end

    test 'chooser options carry channel destinations and stable recipient identities' do
      guardian = create(:constituent, email: "guardian.hint.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        first_name: guardian.first_name,
        last_name: guardian.last_name,
        email: "dependent.hint.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      application = create(:application, user: dependent, status: :awaiting_proof,
                                         medical_provider_name: nil, medical_provider_phone: nil,
                                         medical_provider_email: nil,
                                         managing_guardian: guardian)

      get admin_application_path(application)

      assert_response :success
      masked_guardian_email = "#{guardian.email.first}***@#{guardian.email.split('@', 2).last}"
      assert_select "#provider_info_channel_#{dependent.id} option[value='email']", text: /#{Regexp.escape(masked_guardian_email)}/
      assert_select "#provider_info_channel_#{dependent.id} option[value='email']", text: /ID: #{guardian.id}/
      assert_select "#provider_info_channel_#{guardian.id} option[value='email']", text: /#{Regexp.escape(masked_guardian_email)}/
      assert_select "label[for='provider_info_recipient_#{dependent.id}']", text: /ID: #{dependent.id}/
      assert_select "label[for='provider_info_recipient_#{guardian.id}']", text: /ID: #{guardian.id}/
      assert_select "#provider_info_recipient_#{dependent.id}_destination", count: 0
    end
  end
end
