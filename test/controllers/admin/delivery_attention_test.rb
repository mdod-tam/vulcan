# frozen_string_literal: true

require 'test_helper'

module Admin
  class DeliveryAttentionTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      sign_in_for_integration_test(create(:admin))
      @application = create(:application, :in_progress, medical_certification_status: :requested)
    end

    test 'provider-info attention links to the affected request row' do
      @application = create(:application, status: :awaiting_proof, medical_provider_name: nil, medical_provider_email: nil)
      form = create(:secure_request_form, application: @application)
      assert_attention_target(form, 'ApplicationNotificationsMailer#provider_info_requested', "secure_request_form_#{form.id}")
    end

    test 'proof attention links to the affected request row' do
      form = create(:secure_request_form, application: @application, kind: :residency_proof_resubmission)
      assert_attention_target(form, 'ApplicationNotificationsMailer#proof_resubmission_requested', "secure_request_form_#{form.id}")
    end

    test 'historical income request does not need attention when income proof is not required' do
      form = create(:secure_request_form, application: @application, kind: :income_proof_resubmission)
      attempt = EmailDeliveryAttempt.create!(origin: form, application: @application,
                                             correlation_id: SecureRandom.uuid, destination: 'applicant@example.test',
                                             recipient_key: EmailDeliveryAttempt.recipient_key('applicant@example.test'),
                                             server_id: '23', mail_action: 'ApplicationNotificationsMailer#proof_resubmission_requested',
                                             attempted_at: Time.current, bounced_at: Time.current)
      @application.update!(income_proof_required: false)

      get admin_applications_path
      assert_select "#application_#{@application.id} a", text: I18n.t('delivery_visibility.attention'), count: 0

      get admin_application_path(@application)
      assert_select "#secure_request_form_#{form.id}", count: 0
      assert_predicate form.reload, :active?
      assert attempt.reload.bounced_at
    end

    test 'certification upload attention links to the affected request row' do
      form = create(:medical_provider_secure_request_form, application: @application)
      assert_attention_target(form, 'MedicalProviderMailer#request_certification', "medical_provider_secure_request_form_#{form.id}")
    end

    test 'certification email attention links to the displayed certification delivery' do
      notification = create(:notification, notifiable: @application, action: 'medical_certification_requested')
      assert_attention_target(@application, 'MedicalProviderMailer#request_certification', notification: notification)
    end

    test 'rejection attention links to the exact bounced attempt despite a newer request notification' do
      rejection = create(:notification, notifiable: @application, action: 'medical_certification_rejected', created_at: 1.hour.ago)
      newer_request = create(:notification, notifiable: @application, action: 'medical_certification_requested', delivery_status: :queued)

      attempt = assert_attention_target(@application, 'MedicalProviderMailer#certification_rejected', notification: rejection)

      assert_select "#latest-certification-delivery #email_delivery_attempt_#{attempt.id} [data-delivery-status='bounced']", count: 1
      assert_select "#certification_delivery_notification_#{newer_request.id} [data-delivery-status='queued']", count: 1
      assert_select "#latest-certification-delivery [data-delivery-status='bounced']", count: 1
    end

    test 'certification attempt still has an attention destination after its notification is deleted' do
      notification = create(:notification, notifiable: @application, action: 'medical_certification_requested')
      attempt = assert_attention_target(@application, 'MedicalProviderMailer#request_certification', notification: notification)
      notification.destroy!
      assert_nil attempt.reload.notification_id

      assert_existing_attention_target(ActionView::RecordIdentifier.dom_id(attempt))
    end

    test 'certification delivery keeps queued suppressed and failed notifications without provider attempts' do
      queued = create(:notification, notifiable: @application, action: 'medical_certification_requested', delivery_status: :queued)
      suppressed = create(:notification, notifiable: @application, action: 'medical_certification_rejected')
      suppressed.mark_delivery_suppressed!('global_disabled')
      failed = create(:notification, notifiable: @application, action: 'medical_certification_approved')
      failed.mark_delivery_enqueue_failed!(RuntimeError.new('private provider diagnostics'))

      get admin_application_path(@application)
      { queued => 'queued', suppressed => 'suppressed', failed => 'failed' }.each do |notification, status|
        assert_select "#certification_delivery_notification_#{notification.id} [data-delivery-status='#{status}']", count: 1
      end
      assert_select '#latest-certification-delivery [data-delivery-status]', count: 3
      assert_not_includes response.body, 'private provider diagnostics'
    end

    test 'legacy certification notification with only a placeholder message id does not show a delivery panel' do
      notification = create(:notification, notifiable: @application, action: 'medical_certification_requested',
                                           message_id: 'backfilled-123', delivery_status: :delivered)

      get admin_application_path(@application)
      assert_select '#latest-certification-delivery', count: 0
      assert_select "#certification_delivery_notification_#{notification.id}", count: 0
      assert_select '[data-delivery-status]', count: 0
    end

    private

    def assert_attention_target(origin, action, anchor = nil, notification: nil)
      attempt = EmailDeliveryAttempt.create!(origin: origin, application: @application, notification: notification,
                                             correlation_id: SecureRandom.uuid, destination: 'provider@example.test',
                                             recipient_key: EmailDeliveryAttempt.recipient_key('provider@example.test'),
                                             server_id: '23', mail_action: action, attempted_at: Time.current, bounced_at: Time.current)
      assert_existing_attention_target(anchor || ActionView::RecordIdentifier.dom_id(attempt))
      attempt
    end

    def assert_existing_attention_target(anchor)
      get admin_applications_path
      assert_select "#application_#{@application.id} a[href='#{admin_application_path(@application, anchor: anchor)}']",
                    text: I18n.t('delivery_visibility.attention'), count: 1

      get admin_application_path(@application)
      assert_select "##{anchor} [data-delivery-status='bounced'] summary[aria-label]", count: 1
    end
  end
end
