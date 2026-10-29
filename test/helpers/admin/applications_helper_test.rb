# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsHelperTest < ActionView::TestCase
    include ApplicationsHelper

    setup do
      @application = create(
        :application,
        :in_progress,
        certifying_professional_name: 'Dr. Provider',
        certifying_professional_email: 'provider@example.test'
      )
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

    private

    def attach_disability_certification
      @application.disability_certification.attach(
        io: Rails.root.join('test/fixtures/files/disability_certification_valid.pdf').open,
        filename: 'disability_certification.pdf',
        content_type: 'application/pdf'
      )
    end
  end
end
