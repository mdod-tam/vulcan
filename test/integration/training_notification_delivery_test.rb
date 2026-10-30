# frozen_string_literal: true

require 'test_helper'

# These commands commit for real, so transaction callbacks and delivery outcomes are exercised.
class TrainingNotificationDeliveryTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  include ConcurrencyTestHelper

  PRIVATE_TEXT = 'PRIVATE TRAINING SENTINEL 7319'

  setup do
    @system_actor_existed = PublicAuditActor.system_audit_actor.present?
    @system_actor = ensure_system_audit_actor!
    @admin = create(:admin)
    @trainer = create(:trainer)
    @constituent = create(:constituent)
    @application = create(:application, :approved, :with_all_proofs, user: @constituent, application_date: Date.current,
                                                                     assigned_trainer: @trainer)
    @product = create(:product)
    @old_adapter = EmailDelivery::MailDeliveryJob.queue_adapter
    EmailDelivery::MailDeliveryJob.queue_adapter = :test
    EmailDelivery::MailDeliveryJob.queue_adapter.enqueued_jobs.clear
    ActionMailer::Base.deliveries.clear
    load_seeded_email_templates(*%w[training_scheduled training_rescheduled training_cancelled training_no_show training_completed].map do |action|
      "training_session_notifications_#{action}"
    end)
  end

  teardown do
    EmailDelivery::MailDeliveryJob.queue_adapter.enqueued_jobs.clear
    EmailDelivery::MailDeliveryJob.queue_adapter = @old_adapter
    PrintQueueItem.where(application: @application).destroy_all
    RoleCapability.where(user_id: [@trainer.id, @replacement_trainer&.id].compact).delete_all
    cleanup_duplicate_review_test_data!(@admin, @trainer, @replacement_trainer, @constituent, @guardian, @other_guardian, (@system_actor unless @system_actor_existed))
    @product.destroy!
  end

  test 'real scheduling and follow-up creation each queue one intended notice' do
    session = create(:training_session, application: @application, trainer: @trainer)
    result = schedule(session)
    assert result.success?, result.message
    assert_equal :queued, result.data[:notification_outcome].status
    assert_equal 1, mail_jobs.length
    assert_equal @trainer.id, notification(session, 'training_scheduled').actor_id

    duplicate = schedule(session)
    assert_not duplicate.success?
    assert_equal 1, mail_jobs.length

    result = TrainingSessions::CancelService.new(session, @trainer, cancellation_reason: PRIVATE_TEXT, cancellation_initiator: 'trainer').call
    assert result.success?, result.message
    result = TrainingSessions::ScheduleFollowUpService.new(
      session, @trainer, scheduled_for: 3.days.from_now, location: 'Library room 2', reschedule_reason: PRIVATE_TEXT
    ).call
    assert result.success?, result.message
    assert_equal :queued, result.data[:notification_outcome].status
    assert_equal 1, Notification.where(notifiable: result.data[:training_session], action: 'training_scheduled').count
    assert_equal 3, mail_jobs.length
    assert_private_metadata_absent
  end

  test 'reschedule uses captured old date and actor without publishing the private reason' do
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
    old_date = session.scheduled_for
    result = nil
    Application.transaction do
      result = TrainingSessions::RescheduleService.new(
        session, @trainer, scheduled_for: 3.days.from_now, location: 'Library room 2', reschedule_reason: PRIVATE_TEXT
      ).call
      assert result.success?, result.message
      assert_equal :deferred, result.data[:notification_outcome].status
      assert_empty mail_jobs
      Current.user = @admin
    end

    notice = notification(session, 'training_rescheduled')
    assert_equal old_date.iso8601, notice.metadata['old_scheduled_for']
    assert_equal @trainer.id, notice.actor_id
    assert_equal :queued, result.data[:notification_outcome].status
    assert_equal 1, mail_jobs.length
    assert_private_metadata_absent
    mail = TrainingSessionNotificationsMailer.training_rescheduled(session, notice).message
    assert_includes mail.body.decoded, 'Library room 2'
    assert_includes mail.body.decoded, old_date.strftime('%Z')
    assert_not_includes mail.body.decoded, PRIVATE_TEXT
  end

  test 'outer rollback queues no notification and rolls back state and audit' do
    session = create(:training_session, application: @application, trainer: @trainer)
    Application.transaction do
      result = schedule(session)
      assert result.success?, result.message
      assert_equal :deferred, result.data[:notification_outcome].status
      raise ActiveRecord::Rollback
    end

    assert session.reload.status_requested?
    assert_empty mail_jobs
    assert_not Notification.exists?(notifiable: session)
    assert_not Event.exists?(auditable: session, action: 'training_scheduled')
  end

  test 'notification exception preserves the committed operation and exposes failed outcome' do
    session = create(:training_session, application: @application, trainer: @trainer)
    NotificationService.stubs(:create_and_deliver!).raises(RuntimeError, PRIVATE_TEXT)
    result = schedule(session)

    assert result.success?, result.message
    assert session.reload.status_scheduled?
    assert Event.exists?(auditable: session, action: 'training_scheduled')
    assert_equal :failed, result.data[:notification_outcome].status
    assert_equal 'RuntimeError', result.data[:notification_outcome].error_class
    assert_empty mail_jobs
  end

  test 'completion confirms an early actual visit using public scalar variables and leaves private observations private' do
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer, internal_notes: PRIVATE_TEXT)
    actual_time = 2.hours.ago.change(usec: 0)
    result = TrainingSessions::CompleteService.new(session, @trainer, completion_params(actual_time)).call

    assert result.success?, result.message
    assert_equal :queued, result.data[:notification_outcome].status
    assert_equal actual_time, session.reload.completed_at
    assert_operator session.report_submitted_at, :>, session.completed_at
    assert_equal PRIVATE_TEXT, session.internal_notes
    assert_equal 1, mail_jobs.length
    notice = notification(session, 'training_completed')
    mail = TrainingSessionNotificationsMailer.training_completed(session, notice).message
    assert_includes mail.body.decoded, "/constituent_portal/training_sessions/#{session.id}"
    assert_not_includes mail.body.decoded, PRIVATE_TEXT
    assert_not_includes mail.body.decoded, session.constituent_summary
    assert_private_metadata_absent

    additional = TrainingSessions::ScheduleAdditionalService.new(session, @trainer, scheduled_for: 4.days.from_now).call
    assert additional.success?, additional.message
    assert_equal 1, Notification.where(notifiable: additional.data[:training_session], action: 'training_scheduled').count
    assert_equal 2, mail_jobs.length
  end

  test 'no-show and requested cancellation notify once and stale outcomes do not deliver' do
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer, scheduled_for: 1.hour.from_now)
    result = travel_to(2.hours.from_now) do
      TrainingSessions::NoShowService.new(session, @trainer, no_show_notes: PRIVATE_TEXT).call
    end
    assert result.success?, result.message
    assert_equal 1, mail_jobs.length
    result = TrainingSessions::NoShowService.new(session, @trainer, no_show_notes: PRIVATE_TEXT).call
    assert_not result.success?
    assert_equal 1, mail_jobs.length
    session.destroy!

    requested = create(:training_session, application: @application, trainer: @trainer)
    result = TrainingSessions::CancelService.new(requested, @trainer, cancellation_reason: PRIVATE_TEXT, cancellation_initiator: 'trainer').call
    assert result.success?, result.message
    mail = TrainingSessionNotificationsMailer.training_cancelled(requested, notification(requested, 'training_cancelled')).message
    assert_includes mail.body.decoded, 'unscheduled training request has been closed'
    assert_not_includes mail.body.decoded, 'assignment has been removed'
    assert_equal 2, mail_jobs.length
    assert_private_metadata_absent
  end

  test 'administrative removal queues one cancellation while retaining report history' do
    requested = create(:training_session, application: @application, trainer: @trainer, internal_notes: PRIVATE_TEXT)
    assert_predicate Applications::TrainerAssignment.unassign(@application, actor: @admin, reason: PRIVATE_TEXT), :success?
    assert_equal 1, mail_jobs.length
    notice = notification(requested, 'training_cancelled')
    assert_equal @admin.id, notice.actor_id
    assert_equal 'admin', notice.metadata['cancellation_initiator']
    assert_equal PRIVATE_TEXT, requested.reload.internal_notes
    assert_nil @application.reload.assigned_trainer_id
    assert_private_metadata_absent
  end

  { manager_snapshot: :guardian, missing_snapshot: :guardian, own_snapshot: :constituent,
    independent_snapshot: :constituent, other_guardian_snapshot: :constituent }.each do |strategy, owner_name|
    test "completion email greets the actual #{strategy} contact owner and includes only an authorized report link" do
      configure_completion_contacts(email_strategy: strategy)
      owner = owner_name == :guardian ? @guardian : @constituent
      contact = Applications::ContactContext.new(application: @application)
      assert_equal owner, contact.email_owner
      session = complete_training

      assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
        ActiveJob::Base.execute(mail_jobs.sole)
      end

      email = ActionMailer::Base.deliveries.last
      assert_equal [contact.email], email.to
      assert_equal 'email', notification(session, 'training_completed').reload.metadata['actual_delivery_channel']
      assert_completion_body(email.body.decoded, recipient: owner, session: session)
      assert_empty PrintQueueItem.where(application: @application)
      assert_private_metadata_absent
    end
  end

  test 'managing guardian receives completion in their language through the chosen channel' do
    @guardian = create(:constituent, locale: 'es', communication_preference: :letter)
    @other_guardian = create(:constituent, locale: 'en')
    @constituent.update!(email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: @guardian.email)
    create(:guardian_relationship, guardian_user: @other_guardian, dependent_user: @constituent)
    create(:guardian_relationship, guardian_user: @guardian, dependent_user: @constituent)
    @application.update!(managing_guardian: @guardian)
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer, internal_notes: PRIVATE_TEXT)
    result = TrainingSessions::CompleteService.new(session, @trainer, completion_params(2.hours.ago)).call

    assert result.success?, result.message
    assert_equal :queued, result.data[:notification_outcome].status
    assert_equal 1, mail_jobs.length
    renderer = execute_completion_letter
    assert_empty ActionMailer::Base.deliveries
    letter = PrintQueueItem.find_by!(application: @application)
    assert_equal @guardian.id, letter.constituent_id
    assert_equal 'other_notification', letter.letter_type
    assert_predicate letter.pdf_letter, :attached?
    assert_equal 'letter', notification(session, 'training_completed').metadata['actual_delivery_channel']
    assert_equal 'es', letter.delivery_context['template_locale'] if letter.delivery_context.key?('template_locale')
    _, body = renderer.template.render(**renderer.variables)
    assert_completion_body(body, recipient: @guardian, session: session)
    assert_private_metadata_absent
  end

  test 'completion letter greets its guardian address owner even when the applicant owns the email' do
    configure_completion_contacts(email_strategy: :own_snapshot, channel: :letter)
    contact = Applications::ContactContext.new(application: @application)
    assert_equal @constituent, contact.email_owner
    assert_equal @guardian, contact.address_owner
    session = complete_training

    renderer = execute_completion_letter

    letter = PrintQueueItem.find_by!(application: @application)
    assert_equal @guardian.id, letter.constituent_id
    assert_equal @guardian, renderer.recipient
    assert_predicate letter.pdf_letter, :attached?
    assert_empty ActionMailer::Base.deliveries
    assert_completion_body(renderer.template.render(**renderer.variables).last, recipient: @guardian, session: session)
    assert_private_metadata_absent
  end

  test 'an unmanaged dependent receives the completion letter at their own address with their authorized report link' do
    configure_completion_contacts(email_strategy: :own_snapshot)
    @application.update!(managing_guardian: nil)
    @constituent.update!(communication_preference: :letter)
    contact = Applications::ContactContext.new(application: @application)
    assert_equal @constituent, contact.address_owner
    assert_equal 'letter', contact.communication_preference
    session = complete_training

    renderer = execute_completion_letter

    letter = PrintQueueItem.find_by!(application: @application)
    assert_equal @constituent.id, letter.constituent_id
    assert_equal @constituent, renderer.recipient
    assert_predicate letter.pdf_letter, :attached?
    assert_empty ActionMailer::Base.deliveries
    assert_completion_body(renderer.template.render(**renderer.variables).last, recipient: @constituent, session: session)
    assert_private_metadata_absent
  end

  test 'a missing canonical completion email is suppressed instead of inventing a guardian or print fallback' do
    configure_completion_contacts(email_strategy: :other_guardian_snapshot)
    @constituent.update!(email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local")
    contact = Applications::ContactContext.new(application: @application)
    assert_nil contact.email_owner
    assert_equal 'email', contact.communication_preference
    session = complete_training

    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      assert_no_difference -> { PrintQueueItem.where(application: @application).count } do
        ActiveJob::Base.execute(mail_jobs.sole)
      end
    end

    notice = notification(session, 'training_completed')
    assert notice.reload.suppressed_delivery_status?
    assert_equal 'missing_recipient', notice.metadata.dig('delivery_suppressed', 'reason')
  end

  %w[legacy_percent liquid].each do |syntax|
    test "edited #{syntax} completion templates retain their contract and deliver an empty inaccessible report URL" do
      configure_completion_contacts(email_strategy: :own_snapshot)
      template = EmailTemplate.find_by!(name: 'training_session_notifications_training_completed', locale: @constituent.locale, format: :text)
      required = template.required_variables - ['report_access_text']
      body = required.map { |name| syntax == 'liquid' ? "{{ #{name} }}" : "%<#{name}>s" }.join("\n")
      template.update!(syntax: syntax, subject: 'Administrator completion notice', body: body,
                       variables: { 'required' => required, 'optional' => [] })
      attributes = template.reload.attributes
      session = complete_training

      ActiveJob::Base.execute(mail_jobs.sole)

      email = ActionMailer::Base.deliveries.last
      assert_equal [@constituent.email], email.to
      assert_includes email.body.decoded, @constituent.full_name
      assert_not_includes email.body.decoded, '/constituent_portal/training_sessions/'
      assert_equal attributes, template.reload.attributes
      assert_equal 'email', notification(session, 'training_completed').reload.metadata['actual_delivery_channel']
      assert_private_metadata_absent
    end
  end

  test 'policy suppression is distinct from a saved report and creates no mail job' do
    template = EmailTemplate.find_by!(name: 'training_session_notifications_training_completed', format: :text, locale: 'en')
    template.email_control_write = true
    template.update!(enabled: false)
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
    result = TrainingSessions::CompleteService.new(session, @trainer, completion_params(2.hours.ago)).call

    assert result.success?, result.message
    assert session.reload.status_completed?
    assert_equal :suppressed, result.data[:notification_outcome].status
    assert_empty mail_jobs
    assert notification(session, 'training_completed').suppressed_delivery_status?
  end

  test 'covered constituent request reaches the current trainer with an authorized destination' do
    load_seeded_email_templates('application_notifications_training_requested')
    session = create(:training_session, :completed, application: @application, trainer: @trainer, product_trained_on: @product)
    result = Applications::TrainingRequestService.new(application: @application, current_user: @constituent).call

    assert result.success?, result.message
    notice = Notification.find_by!(notifiable: @application, action: 'training_requested')
    assert_equal @trainer.id, notice.recipient_id
    assert_equal @constituent.id, notice.actor_id
    assert_equal [:queued], result.data[:notification_outcomes]
    mail = ApplicationNotificationsMailer.training_requested(@application, notice).message
    assert_includes mail.body.decoded, "/trainers/training_sessions/#{session.id}"
    assert_not_includes mail.body.decoded, '/admin/applications/'
    assert_equal 1, mail_jobs.length
  end

  test 'edited completion subjects render the same public values in the delivered subject and header' do
    { 'legacy_percent' => '%<constituent_full_name>s', 'liquid' => '{{ constituent_full_name }}' }.each do |syntax, placeholder|
      locale = syntax == 'liquid' ? 'es' : 'en'
      @constituent.update!(locale: locale)
      title = locale == 'es' ? 'Capacitación para' : 'Training for'
      template = EmailTemplate.find_by!(name: 'training_session_notifications_training_completed', locale: locale, format: :text)
      body = template.required_variables.map { |name| syntax == 'liquid' ? "{{ #{name} }}" : "%<#{name}>s" }.join("\n")
      template.update!(syntax: syntax, subject: "#{title} #{placeholder}", body: body)
      session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
      result = TrainingSessions::CompleteService.new(session, @trainer, completion_params(1.hour.ago)).call
      assert result.success?, result.message

      ActiveJob::Base.execute(mail_jobs.last)

      mail = ActionMailer::Base.deliveries.last
      assert_equal "#{title} #{@constituent.full_name}", mail.subject
      assert_includes mail.body.decoded, "#{title} #{@constituent.full_name}"
      assert_not_includes mail.body.decoded, placeholder
      assert_not_includes mail.body.decoded, PRIVATE_TEXT
    end
  end

  test 'a queued assignment is suppressed before resolving contacts after removal and reassignment' do
    load_seeded_email_templates('training_session_notifications_trainer_assigned')
    @application.update!(assigned_trainer: nil)
    assert_predicate Applications::TrainerAssignment.assign(@application, @trainer, actor: @admin), :success?
    session = @application.latest_training_session
    notice = notification(session, 'trainer_assigned')
    old_assignment_job = mail_jobs.sole
    assert_predicate Applications::TrainerAssignment.unassign(@application, actor: @admin, reason: 'Coverage changed'), :success?
    @replacement_trainer = create(:trainer)
    @constituent.update!(email: "new-contact-#{SecureRandom.hex(6)}@example.com", physical_address_1: 'Newly private contact address')
    assert_predicate Applications::TrainerAssignment.assign(@application, @replacement_trainer, actor: @admin), :success?

    Applications::ContactContext.expects(:new).never
    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      2.times { ActiveJob::Base.execute(old_assignment_job) }
    end

    assert notice.reload.suppressed_delivery_status?
    assert_equal 'assignment_superseded', notice.metadata.dig('delivery_suppressed', 'reason')
    assert_equal 'none', notice.metadata['actual_delivery_channel']
    assert_equal 1, Event.where(action: EmailDelivery::Outcome::SUPPRESSED).with_metadata(:request_id, old_assignment_job.dig('email_delivery_context', 'request_id')).count
  end

  test 'a queued covered request is suppressed after transfer instead of sending the old trainer new applicant details' do
    load_seeded_email_templates('application_notifications_training_requested')
    create(:training_session, :completed, application: @application, trainer: @trainer, product_trained_on: @product)
    result = Applications::TrainingRequestService.new(application: @application, current_user: @constituent).call
    assert result.success?, result.message
    notice = Notification.find_by!(notifiable: @application, action: 'training_requested')
    assert_equal 'assigned_trainer', notice.metadata['recipient_audience']
    old_request_job = mail_jobs.sole
    assert_predicate Applications::TrainerAssignment.unassign(@application, actor: @admin, reason: 'Coverage changed'), :success?
    @replacement_trainer = create(:trainer)
    @constituent.update!(first_name: 'New private applicant identity')
    assert_predicate Applications::TrainerAssignment.assign(@application, @replacement_trainer, actor: @admin), :success?

    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      ActiveJob::Base.execute(old_request_job)
    end

    assert notice.reload.suppressed_delivery_status?
    assert_equal 'trainer_coverage_changed', notice.metadata.dig('delivery_suppressed', 'reason')
    assert_equal 'none', notice.metadata['actual_delivery_channel']
  end

  test 'an uncovered request keeps its administrative queue audience after a trainer is assigned' do
    load_seeded_email_templates('application_notifications_training_requested', 'training_session_notifications_trainer_assigned')
    @application.update!(assigned_trainer: nil)
    result = Applications::TrainingRequestService.new(application: @application, current_user: @constituent).call
    assert result.success?, result.message
    notice = Notification.find_by!(notifiable: @application, action: 'training_requested', recipient: @admin)
    assert_equal 'assignment_queue_admin', notice.metadata['recipient_audience']
    queue_job = mail_jobs.find { |job| job.dig('email_delivery_context', 'notification_id') == notice.id }
    assert_predicate Applications::TrainerAssignment.assign(@application, @trainer, actor: @admin), :success?

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      ActiveJob::Base.execute(queue_job)
    end

    assert_equal [@admin.email], ActionMailer::Base.deliveries.last.to
    assert_not notice.reload.suppressed_delivery_status?
  end

  test 'trainer assignment remains an email-only staff notice for a letter-preferring trainer' do
    load_seeded_email_templates('training_session_notifications_trainer_assigned')
    @trainer.update!(communication_preference: :letter, physical_address_1: 'Training Office', city: 'Baltimore', state: 'MD', zip_code: '21201')
    @application.update!(assigned_trainer: nil)
    assert_predicate Applications::TrainerAssignment.assign(@application, @trainer, actor: @admin), :success?
    session = @application.latest_training_session
    notice = notification(session, 'trainer_assigned')
    assert_equal 'email', notice.metadata['actual_delivery_channel']
    assert_equal 'email_only', notice.metadata['delivery_route_reason']

    assert_difference -> { ActionMailer::Base.deliveries.count }, 1 do
      ActiveJob::Base.execute(mail_jobs.sole)
    end
    assert_equal [@trainer.email], ActionMailer::Base.deliveries.last.to
    assert_not PrintQueueItem.exists?(application: @application)
  end

  test 'a reassignment tells the new trainer and the constituent that the appointment still stands' do
    load_seeded_email_templates('training_session_notifications_trainer_reassigned', 'training_session_notifications_trainer_changed')
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer, location: 'Agreed library room')
    @replacement_trainer = create(:trainer)

    assert reassign_training(@replacement_trainer)
    assert_equal 2, mail_jobs.length
    mail_jobs.dup.each { |job| ActiveJob::Base.execute(job) }

    to_trainer, to_constituent = ActionMailer::Base.deliveries.sort_by { |mail| mail.to.first == @replacement_trainer.email ? 0 : 1 }
    assert_equal [@replacement_trainer.email], to_trainer.to
    assert_includes to_trainer.body.decoded, 'Any appointment already scheduled has not changed'
    assert_equal [@constituent.email], to_constituent.to
    assert_includes to_constituent.body.decoded, @replacement_trainer.full_name
    assert_includes to_constituent.body.decoded, 'Agreed library room'
    assert_equal @replacement_trainer.id, session.reload.trainer_id
  end

  test 'only the latest of several transfers is delivered, even when the work returns to a former recipient' do
    load_seeded_email_templates('training_session_notifications_trainer_reassigned', 'training_session_notifications_trainer_changed')
    create(:training_session, :scheduled, application: @application, trainer: @trainer)
    @replacement_trainer = create(:trainer)

    [@replacement_trainer, @trainer, @replacement_trainer].each { |trainer| assert reassign_training(trainer) }
    assert_equal 6, mail_jobs.length
    mail_jobs.dup.each { |job| ActiveJob::Base.execute(job) }

    assert_equal [@replacement_trainer.email, @constituent.email].sort, ActionMailer::Base.deliveries.flat_map(&:to).sort
    superseded = Notification.where(action: %w[trainer_reassigned training_trainer_changed]).select(&:suppressed_delivery_status?)
    assert_equal 4, superseded.length
    assert_equal ['assignment_superseded'], superseded.map { |notice| notice.metadata.dig('delivery_suppressed', 'reason') }.uniq
  end

  test 'a transfer notice is not sent to a recipient who lost trainer access before delivery' do
    load_seeded_email_templates('training_session_notifications_trainer_reassigned', 'training_session_notifications_trainer_changed')
    create(:training_session, :scheduled, application: @application, trainer: @trainer)
    @replacement_trainer = create(:trainer)
    assert reassign_training(@replacement_trainer)
    trainer_job = mail_jobs.find { |job| job[:args][1] == 'trainer_reassigned' }

    @replacement_trainer.update_columns(status: User.statuses[:suspended])
    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      ActiveJob::Base.execute(trainer_job)
    end
    assert_equal 'assignment_superseded', notification(@application.latest_training_session, 'trainer_reassigned').metadata.dig('delivery_suppressed', 'reason')

    Users::Trainer.where(id: @replacement_trainer.id).update_all(type: 'Users::Constituent')
    assert_nothing_raised { ActiveJob::Base.execute(trainer_job) }
    assert_empty ActionMailer::Base.deliveries
  end

  %i[email letter].each do |channel|
    test "the #{channel} notice telling the constituent about a new trainer is not sent after that trainer's access is removed" do
      load_seeded_email_templates('training_session_notifications_trainer_reassigned', 'training_session_notifications_trainer_changed')
      @constituent.update!(communication_preference: channel, physical_address_1: 'Constituent Avenue', city: 'Baltimore', state: 'MD', zip_code: '21201')
      create(:training_session, :scheduled, application: @application, trainer: @trainer)
      @replacement_trainer = create(:evaluator)
      create(:role_capability, user: @replacement_trainer, capability: 'can_train')
      assert reassign_training(@replacement_trainer)
      constituent_job = mail_jobs.find { |job| job[:args][1] == 'trainer_changed' }
      remove_training_access(@replacement_trainer)

      assert_no_difference -> { ActionMailer::Base.deliveries.count + PrintQueueItem.where(application: @application).count } do
        ActiveJob::Base.execute(constituent_job)
      end

      notice = Notification.find_by!(action: 'training_trainer_changed', recipient: @constituent)
      assert_equal 'assignment_superseded', notice.metadata.dig('delivery_suppressed', 'reason')
    end
  end

  test 'a transfer notice whose assignment no longer exists is recorded as not sent, not retried' do
    load_seeded_email_templates('training_session_notifications_trainer_reassigned', 'training_session_notifications_trainer_changed')
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer)
    @replacement_trainer = create(:trainer)
    assert reassign_training(@replacement_trainer)
    jobs = mail_jobs.dup
    TrainingSession.where(id: session.id).delete_all

    assert_no_difference -> { ActionMailer::Base.deliveries.count } do
      assert_difference -> { Event.where(action: EmailDelivery::Outcome::SUPPRESSED).count }, jobs.length do
        jobs.each { |job| assert_nothing_raised { ActiveJob::Base.execute(job) } }
      end
    end
  end

  private

  def configure_completion_contacts(email_strategy:, channel: :email)
    @guardian = create(:constituent, first_name: 'Managing', last_name: 'Guardian', locale: 'es',
                                     communication_preference: channel, physical_address_1: 'Managing Guardian Avenue')
    @other_guardian = create(:constituent, first_name: 'Another', last_name: 'Guardian', locale: 'en')
    create(:guardian_relationship, guardian_user: @other_guardian, dependent_user: @constituent)
    create(:guardian_relationship, guardian_user: @guardian, dependent_user: @constituent)
    @constituent.update!(first_name: 'Learning', last_name: 'Applicant', locale: 'en')
    case email_strategy
    when :manager_snapshot
      @constituent.update!(email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local", dependent_email: @guardian.email)
    when :missing_snapshot
      @constituent.update!(dependent_email: nil)
    when :own_snapshot
      @constituent.update!(dependent_email: @constituent.email)
    when :independent_snapshot
      @constituent.update!(dependent_email: "own-contact-#{SecureRandom.hex(6)}@example.com")
    when :other_guardian_snapshot
      @constituent.update!(dependent_email: @other_guardian.email)
    end
    @application.update!(managing_guardian: @guardian)
  end

  def complete_training
    session = create(:training_session, :scheduled, application: @application, trainer: @trainer, internal_notes: PRIVATE_TEXT)
    result = TrainingSessions::CompleteService.new(session, @trainer, completion_params(2.hours.ago)).call
    assert result.success?, result.message
    assert_equal :queued, result.data[:notification_outcome].status
    assert_equal 1, mail_jobs.length
    session.reload
  end

  def execute_completion_letter
    renderers = []
    constructor = Letters::TextTemplateToPdfService.method(:new)
    observer = lambda do |**arguments|
      constructor.call(**arguments).tap { |renderer| renderers << renderer }
    end
    # Observe real inputs while the production renderer generates and queues its PDF.
    assert_difference -> { PrintQueueItem.where(application: @application).count }, 1 do
      Letters::TextTemplateToPdfService.stub(:new, observer) { ActiveJob::Base.execute(mail_jobs.sole) }
    end
    renderers.sole
  end

  def assert_completion_body(body, recipient:, session:)
    greeting = recipient.locale == 'es' ? "Hola #{recipient.full_name}:" : "Hello #{recipient.full_name},"
    assert_includes body, greeting
    accessible = Application.accessible_by(recipient).exists?(@application.id)
    if accessible
      assert_includes body, "/constituent_portal/training_sessions/#{session.id}"
      assert_includes body, I18n.t('training_session_notifications.training_completed.report_accessible', locale: recipient.locale)
    else
      assert_not_includes body, '/constituent_portal/training_sessions/'
      assert_includes body, I18n.t('training_session_notifications.training_completed.report_managed', locale: recipient.locale)
    end
    assert_not_includes body, PRIVATE_TEXT
    assert_not_includes body, session.constituent_summary
  end

  def schedule(session)
    TrainingSessions::ScheduleService.new(session, @trainer,
                                          scheduled_for: 2.days.from_now, location: 'Library room 2', internal_notes: PRIVATE_TEXT).call
  end

  def completion_params(actual_time)
    { completed_at: actual_time, constituent_summary: 'We practised using captions.', summary_locale: 'en',
      duration_hours: '1.5', product_trained_on_id: @product.id }
  end

  def remove_training_access(trainer)
    intent = Users::CapabilityWriter::Intent.revoke('can_train')
    operation_id = SecureRandom.uuid
    token = Users::CapabilityWriter.call(actor: @admin, user: trainer, intent: intent, operation_id: operation_id, confirmation: nil).token
    result = Users::CapabilityWriter.call(actor: @admin, user: trainer, intent: intent, operation_id: operation_id, confirmation: token)
    assert result.changed?, result.message
  end

  def reassign_training(trainer)
    Applications::TrainerAssignment.reassign(@application.reload, trainer, actor: @admin, expected_version: @application.training_assignment_version)
  end

  def notification(session, action)
    Notification.find_by!(notifiable: session, action: action)
  end

  def mail_jobs
    EmailDelivery::MailDeliveryJob.queue_adapter.enqueued_jobs.select { |job| job[:job] == EmailDelivery::MailDeliveryJob }
  end

  def assert_private_metadata_absent
    notifications = Notification.where(notifiable_type: 'TrainingSession', notifiable_id: @application.training_sessions.select(:id))
    assert_not_includes notifications.pluck(:metadata).to_json, PRIVATE_TEXT
    assert_not_includes Event.where(auditable_type: 'TrainingSession', auditable_id: @application.training_sessions.select(:id)).pluck(:metadata).to_json, PRIVATE_TEXT
  end
end
