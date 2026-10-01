# frozen_string_literal: true

require 'test_helper'

module Applications
  # Delivery outcomes for issued secure links, with real mailers.
  class SecureLinkDeliveryContractTest < ActiveSupport::TestCase
    include ActiveSupport::Testing::TimeHelpers

    setup do
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
      application = create(:application, :in_progress, medical_provider_name: 'Dr. Original',
                                                       medical_provider_email: 'original-provider@example.test')
      first = RequestCertificationUpload.new(application: application, actor: @admin).call
                                        .data.fetch(:medical_provider_secure_request_form)
      application.update!(medical_provider_email: 'current-provider@example.test')

      travel_to first.sent_at + 2.hours do
        result = RequestCertificationUpload.new(application: application, actor: @admin, resend_of: first,
                                                deliver_email: true).call
        assert_predicate result, :success?
      end

      assert_equal ['current-provider@example.test'], ActionMailer::Base.deliveries.last.to
      replacement = application.medical_provider_secure_request_forms.order(:sent_at).last
      assert_equal 'current-provider@example.test', replacement.provider_email
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
      application = create(:application, :in_progress)
      RequestProofResubmission.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'No usable contact path is available for this recipient.', data: nil)
      )

      review = create(:proof_review, :rejected, application: application, admin: @admin, proof_type: :income)

      event = Event.find_by!(action: 'proof_resubmission_request_failed', auditable: application)
      assert_equal review.id, event.metadata['proof_review_id']
      assert_equal 'income', event.metadata['proof_type']
      assert_equal 'No usable contact path is available for this recipient.', event.metadata['reason']
    end
  end
end
