# frozen_string_literal: true

require 'test_helper'

module Webhooks
  class DocusealActivityConcurrencyTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    include ConcurrencyTestHelper

    %w[viewed started declined].each do |activity|
      test "concurrent #{activity} deliveries wait for one durable audit event" do
        existing_system_actor = User.system_user
        system_actor = ensure_system_audit_actor!
        owner = create(:constituent)
        application = create(:application, :in_progress, user: owner, document_signing_service: 'docuseal',
                                                         document_signing_submission_id: "activity_#{SecureRandom.hex(4)}",
                                                         document_signing_submitter_id: 'signer_42', document_signing_requested_at: 1.day.ago,
                                                         document_signing_status: :sent, disability_certification_status: :requested)
        payload = { event_type: "form.#{activity}", timestamp: 1.hour.ago.utc.iso8601(6),
                    data: { id: 'signer_42', submission_id: application.document_signing_submission_id } }
        secret = 'activity-concurrency-signing-secret'
        Rails.application.credentials.stubs(:webhook_secret).returns(secret)

        holder_ready = Queue.new
        release_holder = Queue.new
        holder_pid_queue = Queue.new
        holder_status = nil
        holder_thread = on_own_connection do
          holder_pid_queue << backend_pid
          ActiveRecord::Base.transaction do
            holder_status = deliver_activity(payload, secret)
            holder_ready << true
            release_holder.pop
          end
        end
        holder_pid = wait_for_signal(holder_pid_queue, thread: holder_thread)
        wait_for_signal(holder_ready, thread: holder_thread)

        contender_pid_queue = Queue.new
        contender_status = nil
        contender_thread = on_own_connection do
          contender_pid_queue << backend_pid
          contender_status = deliver_activity(payload, secret)
        end

        confirm_blocked_then_release(
          wait_for_signal(contender_pid_queue, thread: contender_thread),
          holder_pid:, release_queue: release_holder, holder_thread:, contender_thread:
        )

        assert_equal [200, 200], [holder_status, contender_status]
        events = Event.where(auditable: application, action: "document_signing_#{activity}")
        assert_equal 1, events.count
        assert_equal system_actor.id, events.first.user_id
        assert_equal payload[:timestamp], events.first.metadata["#{activity}_at"]
        assert_equal({ 'viewed' => 'opened', 'started' => 'sent', 'declined' => 'declined' }.fetch(activity),
                     application.reload.document_signing_status)
      ensure
        cleanup_duplicate_review_test_data!(owner)
        cleanup_duplicate_review_test_data!(system_actor) unless existing_system_actor
      end
    end

    private

    def deliver_activity(payload, secret)
      body = payload.to_json
      timestamp = Time.current.to_i
      digest = OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{body}")
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post webhooks_docuseal_disability_certification_path, params: body,
                                                                    headers: { 'Content-Type' => 'application/json',
                                                                               'X-Docuseal-Signature' => "#{timestamp}.#{digest}" }
      session.response.status
    end
  end
end
