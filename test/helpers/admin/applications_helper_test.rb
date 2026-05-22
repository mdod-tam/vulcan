# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsHelperTest < ActionView::TestCase
    include ApplicationsHelper

    setup do
      @application = create(
        :application,
        :in_progress,
        medical_provider_name: 'Dr. Provider',
        medical_provider_email: 'provider@example.test'
      )
    end

    test 'medical certification action state derives requested after rejection from notifications' do
      reject = create(
        :notification,
        notifiable: @application,
        recipient: @application.user,
        action: 'medical_certification_rejected',
        created_at: 2.hours.ago
      )
      request = create(
        :notification,
        notifiable: @application,
        recipient: @application.user,
        action: 'medical_certification_requested',
        created_at: 1.hour.ago
      )

      state = medical_certification_action_state(@application, secure_request_forms: [])

      assert_equal request, state.latest_certification_request
      assert_equal reject, state.latest_certification_reject
      assert_predicate state, :requested_after_rejection
    end

    test 'medical certification action state counts active secure upload forms' do
      active_form = create(:medical_provider_secure_request_form, application: @application)
      create(:medical_provider_secure_request_form, :submitted, application: @application)

      state = medical_certification_action_state(@application, secure_request_forms: @application.medical_provider_secure_request_forms)

      assert_equal 1, state.active_secure_cert_upload_forms
      assert_equal 'A secure upload link is already active. Send DocuSeal as an additional option?',
                   state.docuseal_confirm
      assert_predicate active_form.reload, :active?
    end

    test 'medical certification action state describes multiple active secure upload forms as additional DocuSeal options' do
      create(:medical_provider_secure_request_form, application: @application, provider_email: 'primary@example.test')
      create(:medical_provider_secure_request_form, application: @application, provider_email: 'backup@example.test')

      state = medical_certification_action_state(@application, secure_request_forms: @application.medical_provider_secure_request_forms)

      assert_equal 2, state.active_secure_cert_upload_forms
      assert_equal '2 secure upload links are already active. Send DocuSeal as an additional option?',
                   state.docuseal_confirm
    end

    test 'medical certification action state reflects provider readiness and DocuSeal additional option copy' do
      @application.update!(document_signing_status: :sent)

      state = medical_certification_action_state(@application, secure_request_forms: [])

      assert_predicate state, :provider_ready_for_docuseal
      assert_equal 'A DocuSeal request is already sent. Send a secure upload link as an additional option?',
                   state.secure_cert_upload_confirm
      assert_equal I18n.t('admin.applications.certification_upload_requests.create.provider_email_required'),
                   state.secure_cert_upload_message
    end

    test 'secure cert upload button is hidden while an uploaded certification is pending review' do
      @application.update!(medical_certification_status: :received)
      @application.medical_certification.attach(
        io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
        filename: 'medical_certification.pdf',
        content_type: 'application/pdf'
      )

      assert_predicate @application, :medical_certification_status_received?
      assert medical_certification_pending_review?(@application)
      assert_not show_secure_cert_upload_button?(@application)
    end

    test 'secure cert upload button returns after rejection even when the rejected file remains attached' do
      @application.update!(medical_certification_status: :rejected)
      @application.medical_certification.attach(
        io: Rails.root.join('test/fixtures/files/medical_certification_valid.pdf').open,
        filename: 'medical_certification.pdf',
        content_type: 'application/pdf'
      )

      assert_not medical_certification_pending_review?(@application)
      assert show_secure_cert_upload_button?(@application)
    end

    test 'voucher assignment detail describes assignment methods' do
      metadata = {
        'voucher_code' => 'ABC123',
        'initial_value' => 500,
        'issued_at' => '2026-05-21T12:00:00Z'
      }

      assert_includes voucher_assignment_detail(metadata.merge('assignment_method' => 'manual'), fallback_time: Time.zone.now),
                      'manually issued'
      assert_includes voucher_assignment_detail(metadata.merge('assignment_method' => 'manual_approval'), fallback_time: Time.zone.now),
                      'manually issued'
      assert_includes voucher_assignment_detail(metadata.merge('assignment_method' => 'automatic'), fallback_time: Time.zone.now),
                      'automatically issued'
      assert_includes voucher_assignment_detail(metadata.merge('assignment_method' => 'backfill'), fallback_time: Time.zone.now),
                      'issued via backfill'
    end
  end
end
