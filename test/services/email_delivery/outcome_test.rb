# frozen_string_literal: true

require 'test_helper'
require 'timeout'

# Outcome identity needs committed, competing connections. Queue-boundary tests cover its callers.
class EmailDeliveryOutcomeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper

  ACTIONS = %w[email_delivery_suppressed email_delivery_configuration_error email_delivery_enqueue_failed essential_communication_submitted].freeze

  setup do
    @threads = []
    @release = Queue.new
    @request_id = SecureRandom.uuid
    @actor_existed = PublicAuditActor.system_audit_actor.present?
    @actor = ensure_system_audit_actor!
    @initial_event_ids = @actor.events.ids
  end

  teardown do
    2.times { @release << true }
    @threads.each { |thread| thread.join(10) || thread.kill }
    @actor.events.where.not(id: @initial_event_ids).delete_all
    cleanup_duplicate_review_test_data!(@actor) unless @actor_existed
    EmailDelivery::Current.reset
  end

  test 'competing outcomes commit one event and return the same durable request identity' do
    at_insert = Queue.new
    original_create = Event.method(:create!)
    release = @release
    captured_create = lambda do |*arguments, **keywords, &block|
      at_insert << true
      Timeout.timeout(10) { release.pop }
      original_create.call(*arguments, **keywords, &block)
    end

    Event.stub(:create!, captured_create) do
      2.times do
        @threads << Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { record_refusal }
        ensure
          EmailDelivery::Current.reset
        end
      end
      2.times { Timeout.timeout(10) { at_insert.pop } }
      2.times { @release << true }
      results = @threads.map { |thread| Timeout.timeout(10) { thread.value } }

      event = request_events.sole
      assert_equal [event.id, event.id], results.map(&:id)
      assert_equal @actor.id, event.user_id
      assert event.metadata['__service_generated']
    end
  end

  test 'enqueue failure retries retain the original request beyond the ordinary audit window' do
    first = record_enqueue_failure
    travel 1.minute do
      repeated = record_enqueue_failure
      assert_equal first.id, repeated.id
    end
    assert_equal 1, request_events.count
    assert_equal @request_id, request_events.sole.metadata['request_id']
  end

  test 'different actions and requests retain distinct audit facts' do
    record_refusal
    record_refusal(EmailDelivery::Decision.configuration_error(:missing_control))
    record_enqueue_failure
    EmailDelivery::Outcome.record_essential_handoff(context: context.merge('essential_bypassed_controls' => ['communications.global']), channel: :email)
    assert_equal ACTIONS.sort, request_events.order(:action).pluck(:action)

    other_request = SecureRandom.uuid
    EmailDelivery::Outcome.record_not_sent(EmailDelivery::Decision.suppressed(:global_disabled),
                                           context: { 'request_id' => other_request }, mail_action: 'UserMailer#password_reset')
    assert_equal 1, Event.where(action: EmailDelivery::Outcome::SUPPRESSED).with_metadata(:request_id, other_request).count
    assert_equal 4, request_events.count
  end

  test 'contextless and blank request observations remain separate canonical audits' do
    events = [nil, {}, { 'request_id' => '' }, { 'request_id' => '   ' }].map do |capture|
      EmailDelivery::Outcome.record_not_sent(EmailDelivery::Decision.suppressed(:legacy_context_missing),
                                             context: capture, mail_action: 'UserMailer#password_reset')
    end

    assert_equal 4, events.map(&:id).uniq.size
    assert(events.all? { |event| event.metadata['__service_generated'] })
    assert(events.none? { |event| event.metadata.key?('request_id') })
  end

  test 'a duplicate outcome leaves its callers transaction usable' do
    first = record_refusal
    unrelated = nil
    Event.transaction do
      assert_equal first.id, record_refusal.id
      unrelated = AuditEventService.log(action: 'unrelated_outcome_probe', actor: @actor, metadata: { request_id: @request_id })
    end

    assert Event.exists?(unrelated.id)
    assert_equal 1, request_events.count
  end

  test 'database identity enforcement covers every outcome action without constraining other events' do
    ACTIONS.each do |action|
      AuditEventService.log(action: action, actor: @actor, metadata: { request_id: @request_id })
      error = assert_raises(ActiveRecord::RecordNotUnique) do
        Event.transaction(requires_new: true) do
          AuditEventService.log(action: action, actor: @actor, metadata: { request_id: @request_id })
        end
      end
      assert_equal EmailDelivery::Outcome::REQUEST_ID_INDEX, error.cause.result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
    end

    2.times { AuditEventService.log(action: 'unrelated_outcome_probe', actor: @actor, metadata: { request_id: @request_id }) }
    assert_equal 2, Event.where(action: 'unrelated_outcome_probe').with_metadata(:request_id, @request_id).count
  end

  private

  def context
    { 'request_id' => @request_id, 'mail_action' => 'UserMailer#password_reset' }
  end

  def record_refusal(decision = EmailDelivery::Decision.suppressed(:global_disabled))
    EmailDelivery::Outcome.record_not_sent(decision, context: context, mail_action: 'UserMailer#password_reset')
  end

  def record_enqueue_failure
    EmailDelivery::Outcome.record_enqueue_failure(ActiveJob::EnqueueError.new('queue unavailable'), context: context, mail_action: 'UserMailer#password_reset')
  end

  def request_events
    Event.where(action: ACTIONS).with_metadata(:request_id, @request_id)
  end
end
