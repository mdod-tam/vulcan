# frozen_string_literal: true

require 'test_helper'

# Mail jobs against Solid Queue as production runs it: queue tables in the application database,
# reached through their own connection pool, so the queue write is never part of the application's
# transaction. Uses real commits; each test removes what it created.
class MailQueueBoundaryTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  QUEUE_SCHEMA = Rails.root.join('db/queue_schema.rb')

  setup do
    DatabaseCleaner.clean
    @started_at = Time.current
    @control = FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL)
    @control_values = @control.slice(:enabled, :delivery_generation)
    @system_user_existed = User.exists?(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL)
    ensure_system_audit_actor!
    @admin = create(:admin)
    @user = create(:constituent)
    load_seeded_email_templates('user_mailer_password_reset')
    ActionMailer::Base.deliveries.clear
    use_queue_tables_in_application_database!
    @original_adapter = EmailDelivery::MailDeliveryJob.queue_adapter
    EmailDelivery::MailDeliveryJob.queue_adapter = :solid_queue
  end

  teardown do
    EmailDelivery::MailDeliveryJob.queue_adapter = @original_adapter
    drop_queue_tables!
    SolidQueue::Record.connects_to(**Rails.application.config.solid_queue.connects_to)
    # These tests commit, so restore exactly what they changed for the tests that follow.
    Event.where(created_at: @started_at..).delete_all
    @control.update_columns(@control_values)
    Notification.where(recipient: @user).destroy_all
    @training_session&.destroy!
    @application&.destroy!
    @trainer&.destroy!
    @user&.destroy
    @admin&.destroy
    User.where(email: PublicAuditActor::SYSTEM_AUDIT_EMAIL).destroy_all unless @system_user_existed
  end

  test 'the queue uses its own connection to the application database' do
    assert_not_same ActiveRecord::Base.connection, SolidQueue::Record.connection
    assert_equal ActiveRecord::Base.connection.current_database, SolidQueue::Record.connection.current_database
  end

  test 'a rolled-back transaction leaves no mail job' do
    ActiveRecord::Base.transaction do
      request_reset
      raise ActiveRecord::Rollback
    end

    assert_equal 0, mail_jobs.count
  end

  test 'a committed request queues one job carrying the captured controls' do
    ActiveRecord::Base.transaction { request_reset }

    job = mail_jobs.sole
    control = FeatureFlag.find_by!(name: EmailDelivery::GLOBAL_CONTROL)
    scopes = job.arguments.fetch('email_delivery_context').fetch('scopes')
    assert_includes scopes, { 'control' => control.name, 'id' => control.id, 'generation' => control.delivery_generation }
    assert_includes scopes.pluck('control'), EmailDelivery.category_control('account_security')
  end

  test 'mail committed before an off and on interval is not sent when the worker runs it' do
    ActiveRecord::Base.transaction { request_reset }
    set_email(false, 'op-1')
    set_email(true, 'op-2')

    2.times { ActiveJob::Base.execute(mail_jobs.sole.arguments) }

    assert_empty ActionMailer::Base.deliveries
    suppressed = Event.where(action: EmailDelivery::Outcome::SUPPRESSED)
    assert_equal 1, suppressed.count, 'reprocessing the same job records its outcome once'
    assert_equal 'pending_canceled', suppressed.sole.metadata['reason']
  end

  test 'a queued email is delivered when the controls are unchanged' do
    ActiveRecord::Base.transaction { request_reset }

    ActiveJob::Base.execute(mail_jobs.sole.arguments)

    assert_equal [[@user.email]], ActionMailer::Base.deliveries.map(&:to)
  end

  test 'a queue write that fails after commit keeps the committed change and records the failure' do
    SolidQueue::Job.stubs(:enqueue).raises(ActiveJob::EnqueueError, 'queue down')
    job = nil

    ActiveRecord::Base.transaction do
      @user.update!(first_name: 'Committed')
      job = request_reset
    end

    assert_equal 'Committed', @user.reload.first_name
    assert_not job.successfully_enqueued?
    assert_equal 0, mail_jobs.count
    assert Event.exists?(action: EmailDelivery::Outcome::ENQUEUE_FAILED)
  end

  test 'a deferred notification keeps its identity after the caller context has ended' do
    notification = nil
    ActiveRecord::Base.transaction { notification = notify_user }

    context = mail_jobs.sole.arguments.fetch('email_delivery_context')
    assert_equal notification.id, context['notification_id']
    set_email(false, 'op-1')
    ActiveJob::Base.execute(mail_jobs.sole.arguments)

    assert_equal 'suppressed', notification.reload.delivery_status
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_empty ActionMailer::Base.deliveries
  end

  test 'an off and on interval before commit cancels the original request' do
    ActiveRecord::Base.transaction do
      request_reset
      set_email(false, 'op-1')
      set_email(true, 'op-2')
    end

    assert_empty mail_jobs
    assert_equal 'pending_canceled', Event.find_by!(action: EmailDelivery::Outcome::SUPPRESSED).metadata['reason']
  end

  test 'training stays committed but its notification reports a deferred queue failure' do
    @application = create(:application, user: @user)
    @trainer = create(:trainer)
    @training_session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
    reject_mail_inserts!

    TrainingSessionNotifier.new(@training_session).deliver_all

    assert @training_session.reload.status_scheduled?
    notification = Notification.find_by!(notifiable: @training_session, action: 'training_scheduled')
    assert_equal 'error', notification.delivery_status
    assert_equal 'none', notification.metadata['actual_delivery_channel']
    assert_equal 'email_enqueue_failed', notification.metadata['delivery_route_reason']
    assert_match 'could not be queued', notification.email_error_message
    assert_equal 1, Event.where(action: EmailDelivery::Outcome::ENQUEUE_FAILED).count
    assert_equal 'SolidQueue::Job::EnqueueError', Event.find_by!(action: EmailDelivery::Outcome::ENQUEUE_FAILED).metadata['error_class']
    assert_empty mail_jobs
  end

  test 'a real queue insert failure reports enqueue_failed to an immediate caller' do
    reject_mail_inserts!

    assert_equal :enqueue_failed, EmailDelivery.deliver_later(UserMailer.with(user: @user).password_reset)

    event = Event.find_by!(action: EmailDelivery::Outcome::ENQUEUE_FAILED)
    assert_equal 'SolidQueue::Job::EnqueueError', event.metadata['error_class']
    assert_not event.metadata.key?('error_message'), 'adapter SQL errors may contain serialized arguments'
    assert_empty mail_jobs
  end

  test 'rollout removes mail jobs queued without a captured context and keeps the rest' do
    request_reset
    legacy_adapter = ActionMailer::MailDeliveryJob.queue_adapter
    ActionMailer::MailDeliveryJob.queue_adapter = :solid_queue
    ActionMailer::MailDeliveryJob.perform_later('UserMailer', 'password_reset', 'deliver_now', args: [], params: { user: @user })

    assert_match 'UserMailer#password_reset: 1', EmailDelivery::LegacyMailJobs.report
    assert_equal 1, EmailDelivery::LegacyMailJobs.remove!(actor: @admin)

    assert_equal 0, SolidQueue::Job.where(class_name: 'ActionMailer::MailDeliveryJob').count
    assert_equal 1, mail_jobs.count
    event = Event.find_by!(action: EmailDelivery::LegacyMailJobs::AUDIT_ACTION)
    assert_equal 'UserMailer#password_reset', event.metadata['mail_action']
    assert_not event.metadata.key?('arguments')
  ensure
    SolidQueue::Job.where(class_name: 'ActionMailer::MailDeliveryJob').delete_all
    ActionMailer::MailDeliveryJob.queue_adapter = legacy_adapter
  end

  private

  # Exercise the adapter's real database-error wrapper, not a stubbed ActiveJob exception.
  def reject_mail_inserts!
    SolidQueue::Record.connection.add_check_constraint(
      :solid_queue_jobs, "class_name <> 'EmailDelivery::MailDeliveryJob'", name: 'reject_mail_for_test'
    )
  end

  def request_reset
    UserMailer.with(user: @user).password_reset.deliver_later
  end

  def notify_user
    NotificationService.create_and_deliver!(type: 'account_created', recipient: @user, actor: @admin, notifiable: @user)
  end

  def set_email(enabled, operation_id)
    EmailDelivery::ControlWriter.set(name: EmailDelivery::GLOBAL_CONTROL, enabled: enabled, actor: @admin,
                                     operation_id: operation_id)
  end

  def mail_jobs
    SolidQueue::Job.where(class_name: 'EmailDelivery::MailDeliveryJob')
  end

  # Create the queue tables in the application database without recording the queue schema's
  # version there, then give SolidQueue::Record its own pool on that database.
  def use_queue_tables_in_application_database!
    SolidQueue::Record.establish_connection(ActiveRecord::Base.connection_db_config.configuration_hash)
    body = File.read(QUEUE_SCHEMA)[/define\(version: [\d_]+\) do\n(.*)\nend/m, 1]
    SolidQueue::Record.connection.instance_eval(body)
  end

  def drop_queue_tables!
    connection = SolidQueue::Record.connection
    connection.tables.grep(/\Asolid_queue_/).each { |table| connection.drop_table(table, force: :cascade) }
  end
end
