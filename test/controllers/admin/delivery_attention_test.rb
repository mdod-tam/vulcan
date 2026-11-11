# frozen_string_literal: true

require 'test_helper'

module Admin
  class DeliveryAttentionTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      sign_in_for_integration_test(create(:admin), bypass_mfa_enrollment: true)
      @application = create(:application, :in_progress, disability_certification_status: :requested)
    end

    test 'provider-info attention links to the affected request row' do
      @application = create(:application, status: :awaiting_proof, certifying_professional_name: nil, certifying_professional_email: nil)
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
      form = create(:certification_upload_form, application: @application)
      assert_attention_target(form, 'CertifyingProfessionalMailer#request_certification', "secure_request_form_#{form.id}")
    end

    test 'certification email attention links to the displayed certification delivery' do
      notification = create(:notification, notifiable: @application, action: 'disability_certification_requested')
      assert_attention_target(@application, 'CertifyingProfessionalMailer#request_certification', notification: notification)
    end

    test 'rejection attention links to the exact bounced attempt despite a newer request notification' do
      rejection = create(:notification, notifiable: @application, action: 'disability_certification_rejected', created_at: 1.hour.ago)
      newer_request = create(:notification, notifiable: @application, action: 'disability_certification_requested', delivery_status: :queued)

      attempt = assert_attention_target(@application, 'CertifyingProfessionalMailer#certification_rejected', notification: rejection)

      assert_select "#latest-certification-delivery #email_delivery_attempt_#{attempt.id} [data-delivery-status='bounced']", count: 1
      assert_select "#certification_delivery_notification_#{newer_request.id} [data-delivery-status='queued']", count: 1
      assert_select "#latest-certification-delivery [data-delivery-status='bounced']", count: 1
    end

    test 'certification attempt still has an attention destination after its notification is deleted' do
      notification = create(:notification, notifiable: @application, action: 'disability_certification_requested')
      attempt = assert_attention_target(@application, 'CertifyingProfessionalMailer#request_certification', notification: notification)
      notification.destroy!
      assert_nil attempt.reload.notification_id

      assert_existing_attention_target(ActionView::RecordIdentifier.dom_id(attempt))
    end

    test 'certification delivery keeps queued suppressed and failed notifications without provider attempts' do
      queued = create(:notification, notifiable: @application, action: 'disability_certification_requested', delivery_status: :queued)
      suppressed = create(:notification, notifiable: @application, action: 'disability_certification_rejected')
      suppressed.mark_delivery_suppressed!('global_disabled')
      failed = create(:notification, notifiable: @application, action: 'disability_certification_approved')
      failed.mark_delivery_enqueue_failed!(RuntimeError.new('private provider diagnostics'))

      get admin_application_path(@application)
      { queued => 'queued', suppressed => 'suppressed', failed => 'failed' }.each do |notification, status|
        assert_select "#certification_delivery_notification_#{notification.id} [data-delivery-status='#{status}']", count: 1
      end
      assert_select '#latest-certification-delivery [data-delivery-status]', count: 3
      assert_not_includes response.body, 'private provider diagnostics'
    end

    test 'certification history preloads request actors without loading actors for delivery status cards' do
      request_actor = create(:admin)
      status_actor = create(:admin)
      requested = create(:notification, notifiable: @application, actor: request_actor,
                                        action: 'disability_certification_requested', delivery_status: :queued)
      approved = create(:notification, notifiable: @application, actor: status_actor,
                                       action: 'disability_certification_approved', delivery_status: :queued)

      get admin_application_path(@application)

      assert_response :success
      history = @controller.view_assigns.fetch('certification_delivery_notifications')
      status_cards = @controller.view_assigns.fetch('certification_local_delivery_notifications')
      assert_predicate history.find { |notification| notification.id == requested.id }.association(:actor), :loaded?
      assert_not_predicate status_cards.find { |notification| notification.id == approved.id }.association(:actor), :loaded?
      assert_select "#viewCertificationHistoryModal #notification_#{requested.id}", text: /By: #{Regexp.escape(request_actor.full_name)}/
      assert_select "#certification_delivery_notification_#{approved.id} [data-delivery-status='queued']", count: 1
    end

    test 'legacy certification notification with only a placeholder message id does not show a delivery panel' do
      notification = create(:notification, notifiable: @application, action: 'disability_certification_requested',
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
