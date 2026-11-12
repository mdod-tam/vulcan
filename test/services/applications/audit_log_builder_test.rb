# frozen_string_literal: true

require 'test_helper'

module Applications
  class AuditLogBuilderTest < ActiveSupport::TestCase
    setup do
      Application.any_instance.stubs(:verify_proof_attachments).returns(true)

      @application = create(:application,
                            :approved,
                            income_proof_status: :approved,
                            residency_proof_status: :approved)

      prepare_application_for_test(@application, stub_attachments: true)

      @admin = create(:admin)
      @user = create(:constituent)

      @status_change = ApplicationStatusChange.create!(
        application: @application,
        user: @admin,
        from_status: 'draft',
        to_status: 'submitted'
      )

      @proof_review = create(
        :proof_review,
        application: @application,
        admin: @admin,
        proof_type: 'income',
        status: 'approved',
        reviewed_at: 1.hour.ago,
        created_at: 1.day.ago
      )

      @notification = Notification.create!(
        recipient: @user,
        actor: @admin,
        notifiable: @application,
        action: 'proof_approved',
        read_at: nil
      )

      @event = Event.create!(
        user: @admin,
        action: 'application_created',
        auditable: @application,
        metadata: { application_id: @application.id, initial_status: 'approved' }
      )
    end

    teardown do
      Application.any_instance.unstub(:verify_proof_attachments)
    end

    test 'includes status changes in reverse chronological audit logs' do
      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_not_empty logs

        assert_includes logs, @status_change

        timestamps = logs.map { |log| EventDeduplicationService.event_time(log) }
        assert_equal timestamps.sort.reverse, timestamps
        assert_equal @proof_review.reviewed_at, EventDeduplicationService.event_time(logs.grep(ProofReview).sole)
      end
    end

    test 'deduplicated history retains profile changes alongside application events' do
      Current.set(user: @application.user) { @application.user.update!(first_name: 'Changed') }
      profile_event = @application.user.events.where(action: 'profile_updated').order(:id).last

      builder = AuditLogBuilder.new(@application)
      logs = builder.build_deduplicated_audit_logs

      assert_includes logs, profile_event
      assert_includes logs, @status_change
      assert_empty builder.errors
    end

    test 'raw and deduplicated audit output preload the displayed actors and request recipients' do
      request = create(:notification, recipient: @application.user, actor: @admin, notifiable: @application,
                                      action: 'provider_info_requested')

      %i[build_audit_logs build_deduplicated_audit_logs].each do |method|
        logs = AuditLogBuilder.new(@application).public_send(method)
        event = logs.grep(Event).find { |entry| entry.id == @event.id }
        status_change = logs.grep(ApplicationStatusChange).find { |entry| entry.id == @status_change.id }
        review = logs.grep(ProofReview).find { |entry| entry.id == @proof_review.id }
        notification = logs.grep(Notification).find { |entry| entry.id == request.id }

        assert_predicate event.association(:user), :loaded?
        assert_predicate status_change.association(:user), :loaded?
        assert_predicate review.association(:admin), :loaded?
        assert_predicate notification.association(:actor), :loaded?
        assert_predicate notification.association(:recipient), :loaded?
        assert_equal [@admin.id] * 4, [event.user.id, status_change.user.id, review.admin.id, notification.actor.id]
        assert_equal @application.user.id, notification.recipient.id
      end
    end

    test 'deduplicated audit output does not load actors belonging only to discarded certification rows' do
      discarded_actor = create(:admin)
      time = Time.current.beginning_of_minute
      history = ApplicationStatusChange.create!(application: @application, user: @admin,
                                                from_status: 'requested', to_status: 'received',
                                                metadata: { change_type: 'disability_certification' }, created_at: time)
      event = Event.create!(user: discarded_actor, auditable: @application, action: 'disability_certification_status_changed',
                            metadata: { new_status: 'received' }, created_at: time)
      notification = create(:notification, recipient: @application.user, actor: discarded_actor, notifiable: @application,
                                           action: 'disability_certification_received', created_at: time)
      loaded_user_ids = []
      subscriber = lambda do |*, payload|
        next unless payload[:name] == 'User Load'

        loaded_user_ids.concat(payload[:binds].filter_map { |bind| bind.value_for_database if bind.name == 'id' })
      end

      logs = ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
        AuditLogBuilder.new(@application).build_deduplicated_audit_logs
      end

      assert_includes logs, history
      assert_not_includes logs, event
      assert_not_includes logs, notification
      assert_includes loaded_user_ids.flatten, @admin.id
      assert_not_includes loaded_user_ids.flatten, discarded_actor.id

      raw_logs = AuditLogBuilder.new(@application).build_audit_logs
      raw_event = raw_logs.grep(Event).find { |entry| entry.id == event.id }
      raw_notification = raw_logs.grep(Notification).find { |entry| entry.id == notification.id }
      assert_predicate raw_event.association(:user), :loaded?
      assert_predicate raw_notification.association(:actor), :loaded?
      assert_equal discarded_actor.id, raw_event.user.id
      assert_equal discarded_actor.id, raw_notification.actor.id
    end

    test 'returns empty array when application is nil' do
      with_mocked_attachments do
        builder = AuditLogBuilder.new(nil)
        assert_empty builder.build_audit_logs
      end
    end

    test 'includes evaluator transfers with their evaluation owner and excludes other applications' do
      evaluator = create(:evaluator)
      evaluation = create(:evaluation, application: @application, constituent: @application.user, evaluator: evaluator)
      other_evaluation = create(:evaluation)
      transfer = AuditEventService.log(
        action: 'evaluator_reassigned', actor: @admin, auditable: evaluation,
        metadata: { application_id: @application.id, evaluation_id: evaluation.id,
                    previous_evaluator_id: evaluator.id, evaluator_id: create(:evaluator).id,
                    operation_id: SecureRandom.uuid }
      )
      unrelated_transfer = AuditEventService.log(
        action: 'evaluator_reassigned', actor: @admin, auditable: other_evaluation,
        metadata: { application_id: other_evaluation.application_id, evaluation_id: other_evaluation.id,
                    previous_evaluator_id: other_evaluation.evaluator_id, evaluator_id: evaluator.id,
                    operation_id: SecureRandom.uuid }
      )

      logs = AuditLogBuilder.new(@application).build_audit_logs

      assert_includes logs, transfer
      assert_not_includes logs, unrelated_transfer
      displayed = logs.grep(Event).find { |event| event.id == transfer.id }
      assert_equal 'Evaluation', displayed.auditable_type
      assert_equal evaluation.id, displayed.auditable_id
      assert_equal evaluation.id, displayed.metadata['evaluation_id']
      assert_equal @admin.id, displayed.user_id
    end

    test 'deduplicated application history retains both evaluator transfers made in the same minute' do
      Policy.find_or_create_by!(key: 'waiting_period_years').update!(value: 3)
      application = create(:application, :approved, application_date: Date.current)
      evaluator = create(:evaluator)
      replacement = create(:evaluator)
      evaluation = create(:evaluation, application: application, constituent: application.user, evaluator: evaluator)

      freeze_time do
        assert_predicate Applications::EvaluatorAssignment.reassign(application, replacement, actor: @admin), :success?
        assert_predicate Applications::EvaluatorAssignment.reassign(application, evaluator, actor: @admin), :success?

        events = Event.where(action: 'evaluator_reassigned', auditable: evaluation).order(:id).to_a
        displayed = AuditLogBuilder.new(application).build_deduplicated_audit_logs.grep(Event)
                                   .select { |event| event.action == 'evaluator_reassigned' }

        assert_equal 2, events.size
        assert_equal events.map(&:id).sort, displayed.map(&:id).sort
        assert_equal [evaluation.id, evaluation.id], displayed.map(&:auditable_id)
        assert_equal [@admin.id, @admin.id], displayed.map(&:user_id)
      end
    end

    test 'application history retains distinct working-note changes and excludes another application' do
      evaluator = create(:evaluator)
      evaluation = create(:evaluation, application: @application, constituent: @application.user, evaluator: evaluator)
      other_evaluation = create(:evaluation)

      freeze_time do
        %w[First Second].each do |note|
          result = Evaluations::WorkingNotesService.new(evaluation, evaluator, { working_notes: note }).call
          assert result.success?, result.message
        end
        other_result = Evaluations::WorkingNotesService.new(
          other_evaluation, other_evaluation.evaluator, { working_notes: 'Another application' }
        ).call
        assert other_result.success?, other_result.message

        events = Event.where(action: 'evaluation_working_notes_updated', auditable: evaluation).order(:id).to_a
        unrelated = Event.find_by!(action: 'evaluation_working_notes_updated', auditable: other_evaluation)
        displayed = AuditLogBuilder.new(@application).build_deduplicated_audit_logs.grep(Event)
                                   .select { |event| event.action == 'evaluation_working_notes_updated' }

        assert_equal 2, events.size
        assert_equal events.map(&:id).sort, displayed.map(&:id).sort
        assert_not_includes displayed, unrelated
        assert_equal [evaluation.id, evaluation.id], displayed.map(&:auditable_id)
        assert_equal [evaluator.id, evaluator.id], displayed.map(&:user_id)
        assert_equal 2, displayed.map { |event| event.metadata['operation_id'] }.uniq.size
        displayed.each do |event|
          assert_equal @application.id, event.metadata['application_id']
          assert_equal evaluation.id, event.metadata['evaluation_id']
          assert_not_includes event.metadata.to_json, 'First'
          assert_not_includes event.metadata.to_json, 'Second'
        end
      end
    end

    test 'returns empty audit logs after a build failure' do
      failure = ActiveRecord::StatementInvalid.new('audit query unavailable')
      {
        build_audit_logs: 'Failed to build audit logs',
        build_deduplicated_audit_logs: 'Failed to build deduplicated audit logs'
      }.each do |method, message|
        builder = AuditLogBuilder.new(@application)
        logs = capture_rails_logs do
          Event.stub(:select, ->(*) { raise failure }) do
            assert_equal [], builder.public_send(method)
          end
        end

        assert_equal ["#{message}: #{failure.message}"], builder.errors
        assert_includes logs, "#{message}: ActiveRecord::StatementInvalid"
        assert_not_includes logs, failure.message
      end
    end

    test 'includes user profile changes in audit logs' do
      profile_update_event = Event.create!(
        user: @application.user,
        action: 'profile_updated',
        metadata: {
          user_id: @application.user.id,
          changes: {
            'first_name' => { 'old' => 'Old Name', 'new' => 'New Name' },
            'email' => { 'old' => 'old@example.com', 'new' => 'new@example.com' }
          },
          updated_by: @application.user.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, profile_update_event
      end
    end

    test 'includes guardian profile changes for dependent applications' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      dependent_application = create(:application, user: dependent, managing_guardian: guardian)

      guardian_update_event = Event.create!(
        user: guardian,
        action: 'profile_updated_by_guardian',
        metadata: {
          user_id: dependent.id,
          changes: {
            'phone' => { 'old' => '555-123-4567', 'new' => '555-987-6543' }
          },
          updated_by: guardian.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(dependent_application)
        logs = builder.build_audit_logs

        assert_includes logs, guardian_update_event
      end
    end

    test 'includes managing guardian profile changes' do
      guardian = create(:constituent)
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
      dependent_application = create(:application, user: dependent, managing_guardian: guardian)

      guardian_self_update_event = Event.create!(
        user: guardian,
        action: 'profile_updated',
        metadata: {
          user_id: guardian.id,
          changes: {
            'physical_address_1' => { 'old' => '123 Old St', 'new' => '456 New Ave' }
          },
          updated_by: guardian.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(dependent_application)
        logs = builder.build_audit_logs

        assert_includes logs, guardian_self_update_event
      end
    end

    test 'does not include unrelated user profile changes' do
      unrelated_user = create(:constituent)
      unrelated_event = Event.create!(
        user: unrelated_user,
        action: 'profile_updated',
        metadata: {
          user_id: unrelated_user.id,
          changes: {
            'first_name' => { 'old' => 'Unrelated', 'new' => 'User' }
          },
          updated_by: unrelated_user.id,
          timestamp: Time.current.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_not_includes logs, unrelated_event
      end
    end

    test 'profile changes are sorted with other audit logs by created_at' do
      profile_event = Event.create!(
        user: @application.user,
        action: 'profile_updated',
        metadata: {
          user_id: @application.user.id,
          changes: { 'first_name' => { 'old' => 'Old', 'new' => 'New' } },
          updated_by: @application.user.id,
          timestamp: Time.current.iso8601
        },
        created_at: 1.hour.ago
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_equal logs.map(&:created_at), logs.map(&:created_at).sort.reverse

        assert_includes logs, profile_event
      end
    end

    test 'includes closure delivery history and workflow attention events in application audit logs' do
      archive_notice = create(
        :notification,
        recipient: @application.user, actor: @admin, notifiable: @application,
        action: 'max_rejections_reached', delivery_status: :error,
        metadata: { delivery_error: { message: 'The notice could not be queued.', error_class: 'RuntimeError' } }
      )
      events = %w[
        initial_voucher_issuance_attention document_signing_request_unconfirmed document_signing_follow_up_failed
      ].map do |action|
        Event.create!(user: @admin, auditable: @application, action: action,
                      metadata: { application_id: @application.id, operation_id: SecureRandom.uuid })
      end

      builder = AuditLogBuilder.new(@application)
      logs = builder.build_deduplicated_audit_logs

      events.each { |event| assert_includes logs, event }
      loaded_notice = logs.find { |entry| entry.is_a?(Notification) && entry.id == archive_notice.id }
      assert loaded_notice
      assert_equal 'error', loaded_notice.delivery_status
      assert_predicate loaded_notice.association(:email_delivery_attempts), :loaded?
    end

    test 'includes secure request issuance notifications in audit logs' do
      provider_info_notification = create(
        :notification,
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        action: 'provider_info_requested',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 101,
          'request_batch_id' => 'provider-batch',
          'recipient_channel' => 'email',
          'expires_at' => 2.days.from_now.iso8601
        }
      )
      proof_notification = create(
        :notification,
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        action: 'proof_resubmission_requested',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 102,
          'request_batch_id' => 'proof-batch',
          'recipient_channel' => 'email',
          'proof_type' => 'income',
          'expires_at' => 2.days.from_now.iso8601
        }
      )
      cert_notification = create(
        :notification,
        recipient: @application.user,
        actor: @admin,
        notifiable: @application,
        action: 'cert_upload_requested',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 103,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test',
          'requested_channel' => 'email',
          'expires_at' => 2.days.from_now.iso8601
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, provider_info_notification
        assert_includes logs, proof_notification
        assert_includes logs, cert_notification
      end
    end

    test 'bulk loads secure request delivery owners for the audit view' do
      owner = create(:constituent)
      create(:notification, recipient: @application.user, actor: @admin, notifiable: @application,
                            action: 'provider_info_requested', metadata: { 'delivery_owner_id' => owner.id })

      builder = AuditLogBuilder.new(@application)
      builder.build_audit_logs

      assert_equal owner, builder.delivery_owners_by_id[owner.id]
    end

    test 'includes secure request revocation events in audit logs' do
      provider_info_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'provider_info_request_revoked',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 201,
          'request_batch_id' => 'provider-batch',
          'recipient_name' => @application.user.full_name,
          'recipient_channel' => 'email'
        }
      )
      proof_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'proof_resubmission_request_revoked',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 202,
          'request_batch_id' => 'proof-batch',
          'recipient_name' => @application.user.full_name,
          'recipient_channel' => 'email',
          'proof_type' => 'income'
        }
      )
      cert_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'cert_upload_request_revoked',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 203,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test'
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, provider_info_event
        assert_includes logs, proof_event
        assert_includes logs, cert_event
      end
    end

    test 'includes secure request expiration events in audit logs' do
      proof_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'proof_resubmission_request_expired',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 302,
          'request_batch_id' => 'proof-batch',
          'recipient_name' => @application.user.full_name,
          'recipient_channel' => 'email',
          'proof_type' => 'income'
        }
      )
      cert_event = Event.create!(
        user: @admin,
        auditable: @application,
        action: 'cert_upload_request_expired',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 303,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test'
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, proof_event
        assert_includes logs, cert_event
      end
    end

    test 'includes secure form submission events in audit logs' do
      proof_event = Event.create!(
        user: @application.user,
        auditable: @application,
        action: 'proof_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 402,
          'request_batch_id' => 'proof-submit-batch',
          'proof_type' => 'income'
        }
      )
      cert_event = Event.create!(
        user: ensure_system_audit_actor!,
        auditable: @application,
        action: 'cert_submitted_via_secure_form',
        metadata: {
          'application_id' => @application.id,
          'secure_request_form_id' => 403,
          'provider_name' => 'Dr. Provider',
          'provider_email' => 'provider@example.test'
        }
      )

      with_mocked_attachments do
        builder = AuditLogBuilder.new(@application)
        logs = builder.build_audit_logs

        assert_includes logs, proof_event
        assert_includes logs, cert_event
      end
    end
  end
end
