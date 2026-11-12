# frozen_string_literal: true

require 'test_helper'

module Applications
  # Delivery outcomes for issued secure links, with real mailers.
  class SecureLinkDeliveryContractTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
      ensure_system_audit_actor!
      @admin = create(:admin)
      ActionMailer::Base.deliveries.clear
    end

    # The email controls check the template pair before any link exists, so nothing is issued or revoked.
    test 'a turned-off provider information template issues no link and reports suppression' do
      application = create(:application)
      load_seeded_email_templates('application_notifications_provider_info_requested')
      EmailDelivery::ControlWriter.set_template_pair(name: 'application_notifications_provider_info_requested', format: :text,
                                                     enabled: false, actor: @admin, operation_id: 'op-1')

      result = assert_no_difference(-> { application.secure_request_forms.count }) do
        RequestProviderInfo.new(application: application, actor: @admin).call
      end

      assert_not result.success?
      assert_equal 'template_disabled', result.data[:suppression_reason]
      assert_empty ActionMailer::Base.deliveries
    end

    test 'a certification resend goes to the provider email on file now' do
      application = create(:application, :in_progress, certifying_professional_name: 'Dr. Original',
                                                       certifying_professional_email: 'original-provider@example.test')
      first = RequestCertificationUpload.new(application: application, actor: @admin).call
                                        .data.fetch(:secure_request_form)
      application.update!(certifying_professional_email: 'current-provider@example.test')

      travel_to first.sent_at + 2.hours do
        result = RequestCertificationUpload.new(application: application, actor: @admin, resend_of: first,
                                                deliver_email: true).call
        assert_predicate result, :success?
      end

      assert_equal ['current-provider@example.test'], ActionMailer::Base.deliveries.last.to
      replacement = application.certification_upload_forms.order(:sent_at).last
      assert_equal 'current-provider@example.test', replacement.recipient_email
    end

    test 'a W9 resend goes to the vendor email on file now' do
      vendor = create(:vendor, :with_w9)
      vendor.update!(w9_status: :rejected)
      # Creating a rejected review requests a link on its own; keep that out of this test.
      Vendors::RequestW9Resubmission.any_instance.stubs(:call).returns(BaseService::Result.new(success: true, message: 'ok', data: {}))
      create(:w9_review, :rejected, vendor: vendor, admin: @admin, rejection_reason: 'Tax ID mismatch')
      Vendors::RequestW9Resubmission.any_instance.unstub(:call)
      first = Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin).call
                                            .data.fetch(:vendor_secure_request_form)
      # An email change keeps the rejected W9 requestable.
      vendor.update!(email: "current-vendor-#{SecureRandom.hex(3)}@example.test")

      travel_to first.sent_at + 2.hours do
        result = Vendors::RequestW9Resubmission.new(vendor: vendor, actor: @admin, resend_of: first).call
        assert_predicate result, :success?
      end

      assert_equal [vendor.email], ActionMailer::Base.deliveries.last.to
      assert_equal vendor.email, VendorSecureRequestForm.where(vendor: vendor).order(:sent_at).last.recipient_email
    end

    test 'a proof rejection whose link cannot be issued leaves a durable record' do
      failure_message = 'No usable contact path is available for this recipient.'
      private_details = 'private-recipient@example.test token=private-request-token'
      [false, true].each do |unexpected_exception|
        application = create(:application, :in_progress)
        request = RequestProofResubmission.any_instance.stubs(:call)
        if unexpected_exception
          request.raises(StandardError, private_details)
        else
          request.returns(BaseService::Result.new(success: false, message: failure_message, data: nil))
        end

        review = create(:proof_review, :rejected, application: application, admin: @admin, proof_type: :income)
        log_output = StringIO.new
        Rails.stub :logger, ActiveSupport::Logger.new(log_output) do
          assert_no_difference ['SecureRequestForm.count', 'Notification.count'] do
            ProofDecisionFollowUp.new(review).call
          end
        end

        assert_predicate review.reload, :status_rejected?
        event = Event.find_by!(action: 'proof_resubmission_request_failed', auditable: application)
        assert_equal review.id, event.metadata['proof_review_id']
        assert_equal 'income', event.metadata['proof_type']
        expected_reason = unexpected_exception ? 'StandardError' : failure_message
        assert_equal expected_reason, event.metadata['reason']
        assert_includes log_output.string, expected_reason
        assert_not_includes log_output.string, private_details
      end
    end
  end
end
