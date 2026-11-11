# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsHelperTest < ActionView::TestCase
    include ProofResubmissionTestHelper
    include ApplicationsHelper
    include ::ApplicationHelper
    include ::BadgeHelper

    setup do
      @application = create(
        :application,
        :in_progress,
        certifying_professional_name: 'Dr. Provider',
        certifying_professional_email: 'provider@example.test'
      )
    end

    test 'proof review retry fields retain a submitted empty target and stable key' do
      stubs(:params).returns(ActionController::Parameters.new(
                               proof_type: 'disability_certification', status: 'rejected', decision_key: 'retry-key', reviewed_blob_id: ''
                             ))

      assert_equal({ decision_key: 'retry-key', reviewed_blob_id: '' },
                   proof_review_request_params(@application, :disability_certification, :rejected))
    end

    test 'a review missing its submitted target is not silently retargeted on validation rerender' do
      stubs(:params).returns(ActionController::Parameters.new(proof_type: 'income', status: 'rejected', decision_key: 'retry-key'))

      assert_equal({ decision_key: 'retry-key', reviewed_blob_id: 'missing' },
                   proof_review_request_params(@application, :income, :rejected))
      another = proof_review_request_params(@application, :residency, :rejected)
      assert_not_equal 'retry-key', another[:decision_key]
      assert_equal @application.residency_proof.blob&.id, another[:reviewed_blob_id]
    end

    test 'disability certification action state derives requested after rejection from notifications' do
      reject = create(
        :notification,
        notifiable: @application,
        recipient: @application.user,
        action: 'disability_certification_rejected',
        created_at: 2.hours.ago
      )
      request = create(
        :notification,
        notifiable: @application,
        recipient: @application.user,
        action: 'disability_certification_requested',
        created_at: 1.hour.ago
      )

      state = disability_certification_action_state(@application, secure_request_forms: [])

      assert_equal request, state.latest_certification_request
      assert_equal reject, state.latest_certification_reject
      assert_predicate state, :requested_after_rejection
    end

    test 'disability certification action state counts active secure upload forms' do
      active_form = create(:certification_upload_form, application: @application)
      create(:certification_upload_form, :submitted, application: @application)

      state = disability_certification_action_state(@application, secure_request_forms: @application.certification_upload_forms)

      assert_equal 1, state.active_secure_cert_upload_forms
      assert_equal 'A secure upload link is already active. Send DocuSeal as an additional option?',
                   state.docuseal_confirm
      assert_predicate active_form.reload, :active?
    end

    test 'disability certification action state reflects provider readiness and DocuSeal additional option copy' do
      @application.update!(document_signing_status: :sent)

      state = disability_certification_action_state(@application, secure_request_forms: [])

      assert_predicate state, :provider_ready_for_docuseal
      assert_equal 'A DocuSeal request is already sent. Send a secure upload link as an additional option?',
                   state.secure_cert_upload_confirm
      assert_equal I18n.t('admin.applications.certification_upload_requests.create.provider_email_required'),
                   state.secure_cert_upload_message
    end

    test 'secure cert upload button is hidden while an uploaded certification is pending review' do
      @application.update!(disability_certification_status: :received)
      @application.disability_certification.attach(
        io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
        filename: 'disability_certification.pdf',
        content_type: 'application/pdf'
      )

      assert_predicate @application, :disability_certification_status_received?
      assert disability_certification_pending_review?(@application)
      assert_not show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button returns after rejection even when the rejected file remains attached' do
      @application.update!(disability_certification_status: :rejected)
      @application.disability_certification.attach(
        io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
        filename: 'disability_certification.pdf',
        content_type: 'application/pdf'
      )

      assert_not disability_certification_pending_review?(@application)
      assert show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button is hidden for an archived application' do
      @application.update!(disability_certification_status: :rejected)
      assert show_secure_cert_upload_button?(@application)

      @application.update_columns(status: Application.statuses[:archived])

      assert_not show_secure_cert_upload_button?(@application.reload)
    end

    test 'secure cert upload button is hidden when a not requested certification is already attached' do
      @application.update!(disability_certification_status: :not_requested)
      attach_disability_certification

      assert_not show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button is hidden when a requested certification is already attached' do
      @application.update!(disability_certification_status: :requested)
      attach_disability_certification

      assert_not show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button is shown when no certification is attached before initial request' do
      @application.update!(disability_certification_status: :not_requested)
      @application.disability_certification.purge if @application.disability_certification.attached?

      assert show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button is shown when rejected certification has no attachment' do
      @application.update!(disability_certification_status: :rejected)
      @application.disability_certification.purge if @application.disability_certification.attached?

      assert show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button is hidden for approved certification without an attachment' do
      @application.update!(disability_certification_status: :approved)
      @application.disability_certification.purge if @application.disability_certification.attached?

      assert_not show_secure_cert_upload_button?(@application)
    end

    test 'a proof that never arrived reads as not provided, and a reviewed refusal stays rejected' do
      reject_without_file(:income, 'none_provided')
      reject_without_file(:residency, 'illegible')

      assert proof_not_provided?(@application.reload, :income)
      assert_equal 'Not Provided', proof_status_label(@application, :income)
      assert_equal 'Marked not provided on', proof_rejection_verb(proof_rejection_activity(:income))
      assert_not proof_not_provided?(@application, :residency)
      assert_equal 'Rejected', proof_status_label(@application, :residency)
      assert_equal 'Rejected on', proof_rejection_verb(proof_rejection_activity(:residency))
    end

    test 'a later real rejection replaces not provided, and an attached file is never not provided' do
      reject_without_file(:income, 'none_provided')
      travel 1.minute do
        reject_without_file(:income, 'illegible')
      end
      assert_not proof_not_provided?(@application.reload, :income)
      assert_equal 'Rejected', proof_status_label(@application, :income)

      reject_without_file(:id, 'none_provided')
      @application.id_proof.attach(io: Rails.root.join('test/fixtures/files/test_proof.pdf').open,
                                   filename: 'id.pdf', content_type: 'application/pdf')
      @application.reload

      assert_equal 'rejected', @application.id_proof_status, 'precondition: the status is still rejected'
      assert_predicate @application.id_proof, :attached?
      assert_not proof_not_provided?(@application, :id)
    end

    test 'the certification card says not provided when none arrived and rejected when one was refused' do
      reject_certification(@application, 'No disability certification was provided with this application.', 'none_provided')
      refused = create(:application, :in_progress, certifying_professional_name: 'Dr. Provider',
                                                   certifying_professional_email: 'provider@example.test')
      reject_certification(refused, 'Missing provider credentials', nil)

      assert proof_not_provided?(@application.reload, :disability_certification)
      assert_includes disability_certification_card_badge(@application), 'Not Provided'
      assert_not proof_not_provided?(refused.reload, :disability_certification)
      assert_includes disability_certification_card_badge(refused), 'Rejected'
      assert_not_includes disability_certification_card_badge(refused), 'Not Provided'
    end

    test 'provider phone and fax line shows only what the provider has' do
      line = lambda do |phone, fax|
        certifying_professional_phone_fax_line(Application.new(certifying_professional_phone: phone, certifying_professional_fax: fax))
      end

      assert_equal '<p class="text-sm text-gray-600">Phone: 202-555-0199 / Fax: 202-555-0100</p>', line.call('202-555-0199', '202-555-0100')
      assert_equal '<p class="text-sm text-gray-600">Phone: 202-555-0199</p>', line.call('202-555-0199', nil)
      assert_equal '<p class="text-sm text-gray-600">Fax: 202-555-0100</p>', line.call('', '202-555-0100')
      assert_nil line.call(nil, '')
    end

    test 'provider phone and fax line escapes what was typed' do
      line = certifying_professional_phone_fax_line(Application.new(certifying_professional_phone: '<b>1</b>'))

      assert_includes line, 'Phone: &lt;b&gt;1&lt;/b&gt;'
      assert_not_includes line, '<b>'
    end

    private

    def reject_certification(application, reason, reason_code)
      DisabilityCertificationAttachmentService.reject_certification(**proof_decision_params(application, :disability_certification), application: application, admin: create(:admin), reason: reason, reason_code: reason_code, submission_method: :paper)
    end

    def reject_without_file(proof_type, reason)
      ProofAttachmentService.reject_proof_without_attachment(**proof_decision_params(@application, proof_type), application: @application, proof_type: proof_type, admin: create(:admin), reason: reason, submission_method: :paper)
    end

    def proof_rejection_activity(proof_type)
      get_chronological_proof_history(@application, proof_type).rfind { |activity| activity.activity_type == :rejection }
    end

    def attach_disability_certification
      @application.disability_certification.attach(
        io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
        filename: 'disability_certification.pdf',
        content_type: 'application/pdf'
      )
    end
  end
end
