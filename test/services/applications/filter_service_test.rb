# frozen_string_literal: true

require 'test_helper'

module Applications
  class FilterServiceTest < ActiveSupport::TestCase
    include PaperApplicationContextHelpers

    setup do
      # Paper context disables proof consistency validation for these filter fixtures.
      setup_paper_application_context
      @guardian = create(:user,
                         first_name: 'Guardian',
                         last_name: 'User',
                         email: 'guardian_user@example.com',
                         hearing_disability: true)

      @dependent = create(:user,
                          first_name: 'Dependent',
                          last_name: 'User',
                          email: 'dependent_user@example.com',
                          vision_disability: true)

      @guardian_relationship = create(:guardian_relationship,
                                      guardian_user: @guardian,
                                      dependent_user: @dependent,
                                      relationship_type: 'Parent')

      @completed_app_user = create(:user,
                                   first_name: 'Completed',
                                   last_name: 'User',
                                   email: 'completed_user@example.com',
                                   mobility_disability: true)

      @draft_app_user = create(:user,
                               first_name: 'Draft',
                               last_name: 'User',
                               email: 'draft_user@example.com',
                               cognition_disability: true)

      @active_app_user = create(:user,
                                first_name: 'Active',
                                last_name: 'User',
                                email: 'active_user@example.com',
                                speech_disability: true)

      @active_app = create(:application, status: :in_progress, income_proof_status: :not_reviewed, user: @active_app_user)
      @approved_app = create(:application, :completed, user: @completed_app_user)
      @draft_app = create(:application, status: :draft, user: @draft_app_user)

      @dependent_app = create(:application, status: :in_progress, user: @dependent, managing_guardian: @guardian)

      @scope = Application.all
    end

    teardown do
      teardown_paper_application_context
    end

    test 'applies no filters when params are empty' do
      with_mocked_attachments do
        service = FilterService.new(@scope)
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_equal @scope.count, result_data.count
      end
    end

    test 'filters by application status' do
      with_mocked_attachments do
        service = FilterService.new(@scope, { filter: 'in_progress' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
        assert_not_includes result_data, @draft_app
      end
    end

    test 'filters by approved status' do
      with_mocked_attachments do
        service = FilterService.new(@scope, { filter: 'approved' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @approved_app
        assert_not_includes result_data, @active_app
        assert_not_includes result_data, @draft_app
      end
    end

    test 'awaiting proofs includes reminders and preserves the supplied scope' do
      awaiting = create(:application, status: :awaiting_proof)
      reminder = create(:application, status: :reminder_sent)
      create(:application, status: :awaiting_proof)
      supplied = Application.where(id: [awaiting, reminder, @active_app, @approved_app].map(&:id))

      result = FilterService.new(supplied, filter: 'awaiting_proofs').apply_filters

      assert result.success?, result.message
      assert_equal [awaiting.id, reminder.id].sort, result.data.ids.sort
    end

    test 'filters by pending training requests using application state' do
      with_mocked_attachments do
        pending_request = create(:application, :approved, user: create(:constituent, email: 'pending_training_filter@example.com'))
        pending_request.update!(training_requested_at: 1.hour.ago)

        fulfilled_request = create(:application, :approved, user: create(:constituent, email: 'fulfilled_training_filter@example.com'))
        fulfilled_request.update!(training_requested_at: 2.hours.ago)
        create(:training_session, application: fulfilled_request, trainer: create(:trainer), status: :requested)

        notification_only = create(:application, :approved, user: create(:constituent, email: 'notification_only_filter@example.com'))
        create(:notification,
               recipient: create(:admin),
               actor: notification_only.user,
               notifiable: notification_only,
               action: 'training_requested')

        service = FilterService.new(@scope, { filter: 'training_requests' })
        result_data = service.apply_filters.data

        assert_includes result_data, pending_request
        assert_not_includes result_data, fulfilled_request
        assert_not_includes result_data, notification_only
      end
    end

    test 'awaiting training includes pending requests and open sessions once within the supplied scope' do
      trainer = create(:trainer)
      pending = create(:application, :approved, training_requested_at: 3.days.ago, application_date: Date.current)
      requested = create(:application, :approved, training_requested_at: 3.days.ago, application_date: Date.current)
      create(:training_session, application: requested, trainer:)
      scheduled = create(:application, :approved, training_requested_at: 3.days.ago, application_date: Date.current)
      create(:training_session, :completed, application: scheduled, trainer:, completed_at: 4.days.ago, created_at: 5.days.ago)
      create(:training_session, :scheduled, application: scheduled, trainer:)
      completed = create(:application, :approved, training_requested_at: 3.days.ago, application_date: Date.current)
      create(:training_session, :completed, application: completed, trainer:)
      create(:training_session, :scheduled, trainer:)
      supplied = Application.where(id: [pending, requested, scheduled, completed, @approved_app, @active_app].map(&:id))

      result = FilterService.new(supplied, filter: 'awaiting_training').apply_filters

      assert result.success?, result.message
      assert_equal [pending.id, requested.id, scheduled.id].sort, result.data.ids.sort
    end

    test 'filters by proofs needing review only when a file has been submitted' do
      submitted = create(:application, :with_income_proof, status: :in_progress)
      service = FilterService.new(@scope, { filter: 'proofs_needing_review' })
      result = service.apply_filters
      assert_predicate result, :success?
      assert_includes result.data, submitted
      assert_not_includes result.data, @active_app, 'A missing file cannot be reviewed'
      assert_not_includes result.data, @approved_app
    end

    test 'proofs_needing_review excludes income-not-required apps from income portion' do
      application = create(:application, :with_income_proof, status: :in_progress,
                                                             residency_proof_status: :approved, id_proof_status: :approved)
      application.update_columns(income_proof_required: false)
      result = FilterService.new(@scope, { filter: 'proofs_needing_review' }).apply_filters
      assert_predicate result, :success?
      assert_not_includes result.data, application, 'An optional income proof does not require review'
    end

    test 'proofs_needing_review includes submitted residency when income is not required' do
      application = create(:application, :with_residency_proof, status: :in_progress)
      application.update_columns(income_proof_required: false)
      result = FilterService.new(@scope, { filter: 'proofs_needing_review' }).apply_filters
      assert_predicate result, :success?
      assert_includes result.data, application
    end

    test 'filters by disability certifications to review' do
      @active_app.update!(disability_certification_status: :received, status: :in_progress)
      @approved_app.update!(disability_certification_status: :approved, status: :approved)

      @rejected_app_user = create(:user,
                                  first_name: 'Rejected',
                                  last_name: 'User',
                                  email: 'rejected_user@example.com',
                                  speech_disability: true)

      with_mocked_attachments do
        @rejected_app = create(:application,
                               user: @rejected_app_user,
                               status: :rejected,
                               income_proof_status: :not_reviewed,
                               residency_proof_status: :not_reviewed,
                               skip_proofs: true)

        income_proof_mock = mock_attached_file(
          filename: 'income_proof.pdf',
          content_type: 'application/pdf',
          created_at: 1.day.ago
        )
        residency_proof_mock = mock_attached_file(
          filename: 'residency_proof.pdf',
          content_type: 'application/pdf',
          created_at: 1.day.ago
        )
        @rejected_app.stubs(:income_proof).returns(income_proof_mock)
        @rejected_app.stubs(:income_proof_attached?).returns(true)
        @rejected_app.stubs(:residency_proof).returns(residency_proof_mock)
        @rejected_app.stubs(:residency_proof_attached?).returns(true)

        @rejected_app.update_columns(
          income_proof_status: :approved,
          residency_proof_status: :approved
        )

        disability_cert_mock = mock_attached_file(
          filename: 'disability_certification.pdf',
          content_type: 'application/pdf',
          created_at: 1.day.ago
        )
        @rejected_app.stubs(:disability_certification).returns(disability_cert_mock)
        @rejected_app.stubs(:disability_certification_attached?).returns(true)
        @rejected_app.update!(disability_certification_status: :received)

        service = FilterService.new(@scope, { filter: 'disability_certs_to_review' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
        assert_not_includes result_data, @rejected_app, 'Rejected applications should be excluded even with received disability certification'
      end
    end

    test 'combined certification review preserves the supplied scope and the received and signed subfilters' do
      received = create(:application, :in_progress, disability_certification_status: :received)
      signed = create(:application, :in_progress,
                      disability_certification_status: :requested, document_signing_status: :signed, program_disability_groups: ['speech'])
      overlap = create(:application, :in_progress, disability_certification_status: :received, document_signing_status: :signed)
      archived = create(:application, :archived, disability_certification_status: :received, document_signing_status: :signed)
      decided = create(:application, :in_progress, disability_certification_status: :approved, document_signing_status: :signed)
      outsider = create(:application, :in_progress, disability_certification_status: :received)
      supplied = Application.where(id: [received, signed, overlap, archived, decided].map(&:id))
      expected = {
        'certifications_needing_review' => [received.id, signed.id, overlap.id],
        'disability_certs_to_review' => [received.id, overlap.id],
        'digitally_signed_needs_review' => [signed.id, overlap.id]
      }
      expected.each do |filter, ids|
        result = FilterService.new(supplied, filter: filter).apply_filters
        assert result.success?, result.message
        assert_equal ids.sort, result.data.ids.sort, filter
        assert_not_includes result.data.ids, outsider.id
      end
      grouped = FilterService.new(supplied, filter: 'certifications_needing_review', program_group: 'speech').apply_filters
      assert grouped.success?, grouped.message
      assert_equal [signed.id], grouped.data.ids
    end

    test 'certification requests exclude signed and already requested forms within the supplied scope' do
      pending = create(:application, status: :awaiting_dcf, disability_certification_status: :not_requested)
      signed = create(:application, status: :awaiting_dcf, disability_certification_status: :not_requested, document_signing_status: :signed)
      requested = create(:application, status: :awaiting_dcf, disability_certification_status: :requested)
      received = create(:application, status: :awaiting_dcf, disability_certification_status: :received)
      create(:application, status: :awaiting_dcf, disability_certification_status: :not_requested)
      supplied = Application.where(id: [pending, signed, requested, received, @active_app, @approved_app].map(&:id))

      result = FilterService.new(supplied, filter: 'cert_requests_needed').apply_filters

      assert result.success?, result.message
      assert_equal [pending.id], result.data.ids
    end

    test 'filters by explicit status parameter' do
      with_mocked_attachments do
        service = FilterService.new(@scope, { status: 'draft' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @draft_app
        assert_not_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
      end
    end

    test 'active status param includes in-progress workflow apps but excludes draft, approved, rejected, and archived' do
      with_mocked_attachments do
        rejected_app = create(:application,
                              status: :rejected,
                              income_proof_status: :not_reviewed,
                              residency_proof_status: :not_reviewed,
                              skip_proofs: true,
                              user: create(:constituent, email: 'rejected_active@example.com'))
        archived_app = create(:application,
                              status: :archived,
                              income_proof_status: :not_reviewed,
                              residency_proof_status: :not_reviewed,
                              skip_proofs: true,
                              user: create(:constituent, email: 'archived_active@example.com'))

        service = FilterService.new(@scope, { status: 'active' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
        assert_not_includes result_data, @draft_app
        assert_not_includes result_data, rejected_app
        assert_not_includes result_data, archived_app
      end
    end

    test 'filters by date range' do
      with_mocked_attachments do
        @active_app.update!(created_at: Date.current)
        @approved_app.update!(created_at: 60.days.ago)
        @draft_app.update!(created_at: 100.days.ago)

        service = FilterService.new(@scope, { date_range: 'last_30' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
        assert_not_includes result_data, @draft_app
      end
    end

    test 'filters by search term' do
      with_mocked_attachments do
        user1 = create(:constituent,
                       first_name: 'John',
                       last_name: 'Smith',
                       email: 'john.smyth@example.com',
                       vision_disability: true)

        user2 = create(:constituent,
                       first_name: 'Janey',
                       last_name: 'Doe',
                       email: 'janey.doe@example.com',
                       hearing_disability: true)

        @active_app.update!(user: user1)
        @approved_app.update!(user: user2)

        service = FilterService.new(@scope, { q: 'Smith' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
      end
    end

    test 'filters by applicant email search token' do
      with_mocked_attachments do
        matching_user = create(:constituent,
                               first_name: 'Searchable',
                               last_name: 'Applicant',
                               email: 'applicant.anchor@example.com',
                               vision_disability: true)
        other_user = create(:constituent,
                            first_name: 'Other',
                            last_name: 'Applicant',
                            email: 'other.applicant@example.com',
                            hearing_disability: true)
        matching_app = create(:application, status: :draft, user: matching_user)
        other_app = create(:application, status: :draft, user: other_user)

        service = FilterService.new(Application.where(id: [matching_app.id, other_app.id]), { q: 'anchor' })
        service_result = service.apply_filters

        assert service_result.success?
        assert_includes service_result.data, matching_app
        assert_not_includes service_result.data, other_app
      end
    end

    test 'filters by applicant underscore email search token literally' do
      with_mocked_attachments do
        matching_user = create(:constituent,
                               email: 'firstname_lastname@member.senate.gov',
                               vision_disability: true)
        other_user = create(:constituent,
                            email: 'firstnameXlastname@member.senate.gov',
                            hearing_disability: true)
        matching_app = create(:application, status: :draft, user: matching_user)
        other_app = create(:application, status: :draft, user: other_user)

        service = FilterService.new(
          Application.where(id: [matching_app.id, other_app.id]),
          { q: 'firstname_lastname' }
        )
        service_result = service.apply_filters

        assert service_result.success?
        assert_includes service_result.data, matching_app
        assert_not_includes service_result.data, other_app
      end
    end

    test 'search filter still matches application id and applicant name' do
      with_mocked_attachments do
        matching_user = create(:constituent,
                               first_name: 'Ida',
                               last_name: 'Needleman',
                               email: 'ida.needleman@example.com',
                               speech_disability: true)
        other_user = create(:constituent,
                            first_name: 'Other',
                            last_name: 'Person',
                            email: 'other.person@example.com',
                            hearing_disability: true)
        matching_app = create(:application, status: :draft, user: matching_user)
        other_app = create(:application, status: :draft, user: other_user)
        scope = Application.where(id: [matching_app.id, other_app.id])

        name_result = FilterService.new(scope, { q: 'Needleman' }).apply_filters
        id_result = FilterService.new(scope, { q: matching_app.id.to_s }).apply_filters

        assert name_result.success?
        assert_includes name_result.data, matching_app
        assert_not_includes name_result.data, other_app
        assert id_result.success?
        assert_includes id_result.data, matching_app
        assert_not_includes id_result.data, other_app
      end
    end

    test 'filters by managing guardian email search token' do
      with_mocked_attachments do
        guardian = create(:constituent, email: 'guardian.signal@example.com', hearing_disability: true)
        dependent = create(:constituent, email: 'dependent.guardian-filter@example.com', vision_disability: true)
        other_guardian = create(:constituent, email: 'other.guardian@example.com', speech_disability: true)
        other_dependent = create(:constituent, email: 'other.dependent@example.com', mobility_disability: true)
        create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
        create(:guardian_relationship, guardian_user: other_guardian, dependent_user: other_dependent)
        matching_app = create(:application, status: :draft, user: dependent, managing_guardian: guardian)
        other_app = create(:application, status: :draft, user: other_dependent, managing_guardian: other_guardian)

        service = FilterService.new(
          Application.where(id: [matching_app.id, other_app.id]),
          { managing_guardian_q: 'signal' }
        )
        service_result = service.apply_filters

        assert service_result.success?
        assert_includes service_result.data, matching_app
        assert_not_includes service_result.data, other_app
      end
    end

    test 'filters by dependent applicant email search token' do
      with_mocked_attachments do
        matching_user = create(:constituent,
                               email: 'dependent.anchor@example.com',
                               dependent_email: 'child.contact@example.com',
                               vision_disability: true)
        other_user = create(:constituent,
                            email: 'other.dependent-filter@example.com',
                            dependent_email: 'other.contact@example.com',
                            hearing_disability: true)
        matching_app = create(:application, status: :draft, user: matching_user)
        other_app = create(:application, status: :draft, user: other_user)

        service = FilterService.new(
          Application.where(id: [matching_app.id, other_app.id]),
          { dependent_q: 'child' }
        )
        service_result = service.apply_filters

        assert service_result.success?
        assert_includes service_result.data, matching_app
        assert_not_includes service_result.data, other_app
      end
    end

    test 'combines multiple filter parameters' do
      with_mocked_attachments do
        @active_app.update!(status: :in_progress, created_at: Date.current, income_proof_status: :not_reviewed)
        @approved_app.update!(status: :approved, created_at: 60.days.ago)

        service = FilterService.new(@scope, { filter: 'in_progress', date_range: 'last_30' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
      end
    end

    test 'filters by managing guardian' do
      with_mocked_attachments do
        service = FilterService.new(@scope, { managing_guardian_id: @guardian.id })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @dependent_app
        assert_not_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
      end
    end

    test 'filters by applications for dependents of guardian' do
      with_mocked_attachments do
        assert @guardian.dependents.include?(@dependent),
               "Guardian relationship not established - guardian #{@guardian.id} should have dependent #{@dependent.id}"

        service = FilterService.new(@scope, { guardian_id: @guardian.id })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data

        if TestOutput.verbose?
          puts "Guardian ID: #{@guardian.id}"
          puts "Dependent ID: #{@dependent.id}"
          puts "Found guardian relationships: #{GuardianRelationship.where(guardian_id: @guardian.id).count}"
          puts "Active app ID: #{@active_app.id}, user_id: #{@active_app.user_id}"
          puts "Dependent app ID: #{@dependent_app.id}, user_id: #{@dependent_app.user_id}"
        end

        assert_not_includes result_data, @active_app
        assert_includes result_data, @dependent_app
        assert_not_includes result_data, @approved_app
      end
    end

    test 'filters by dependent applications only' do
      with_mocked_attachments do
        service = FilterService.new(@scope, { only_dependent_apps: 'true' })
        service_result = service.apply_filters

        assert service_result.success?, 'Expected service call to be successful'
        result_data = service_result.data
        assert_includes result_data, @dependent_app
        assert_not_includes result_data, @active_app
        assert_not_includes result_data, @approved_app
      end
    end

    # Persisted training_requested_at drives the queue independently of notification delivery.
    test 'filters by training_requests using persisted training_requested_at' do
      with_mocked_attachments do
        approved_app = create(:application, :completed, user: create(:constituent, speech_disability: true))
        approved_app.update_columns(training_requested_at: 1.hour.ago)

        service = FilterService.new(@scope, { filter: 'training_requests' })
        service_result = service.apply_filters

        assert service_result.success?
        result_data = service_result.data
        assert_includes result_data, approved_app
        assert_not_includes result_data, @active_app
      end
    end

    test 'training_requests filter excludes applications without training_requested_at even if they have training sessions' do
      with_mocked_attachments do
        trainer = create(:trainer)

        TrainingSession.create!(
          application: @approved_app,
          trainer: trainer,
          scheduled_for: 1.day.from_now,
          status: :requested
        )

        service = FilterService.new(@scope, { filter: 'training_requests' })
        service_result = service.apply_filters

        assert service_result.success?
        assert_not_includes service_result.data, @approved_app
      end
    end

    test 'training_requests filter ignores notification-only state' do
      with_mocked_attachments do
        admin = create(:admin)
        approved_app = create(:application, :completed, user: create(:constituent, speech_disability: true))

        Notification.create!(
          action: 'training_requested',
          notifiable: approved_app,
          recipient: admin,
          actor: approved_app.user,
          metadata: { application_id: approved_app.id }
        )

        service = FilterService.new(@scope, { filter: 'training_requests' })
        service_result = service.apply_filters

        assert service_result.success?
        assert_not_includes service_result.data, approved_app
      end
    end

    test 'evaluation_requests filter uses evaluation_requested_at only' do
      with_mocked_attachments do
        pending_app = create(:application, :completed, user: create(:constituent, speech_disability: true))
        pending_app.update_columns(evaluation_requested_at: 1.hour.ago)

        no_request_app = create(:application, :completed, user: create(:constituent, speech_disability: true))

        service = FilterService.new(@scope, { filter: 'evaluation_requests' })
        service_result = service.apply_filters

        assert service_result.success?
        assert_includes service_result.data, pending_app
        assert_not_includes service_result.data, no_request_app
      end
    end

    test 'sorts by creation date before limiting results and ignores unsupported sort input' do
      @active_app.update!(created_at: 4.days.ago, application_date: 1.day.ago)
      @approved_app.update!(created_at: 2.days.ago, application_date: 7.days.ago)
      @draft_app.update!(created_at: 3.days.ago)
      scope = Application.where(id: [@active_app.id, @approved_app.id, @draft_app.id]).order(application_date: :desc)

      newest = FilterService.new(scope, sort: 'created_at', direction: 'desc').apply_filters.data
      assert_equal [@approved_app.id, @draft_app.id], newest.limit(2).pluck(:id)
      assert_equal 3, newest.count
      assert_equal [@active_app.id, @draft_app.id, @approved_app.id],
                   FilterService.new(scope, sort: 'created_at', direction: 'asc').apply_filters.data.pluck(:id)
      assert_equal newest.pluck(:id), FilterService.new(scope, sort: 'applications.id; SELECT 1', direction: 'sideways').apply_filters.data.pluck(:id)
      malicious_direction = FilterService.new(scope, sort: 'created_at', direction: 'DESC; SELECT pg_sleep(10)').apply_filters
      assert malicious_direction.success?
      assert_equal newest.pluck(:id), malicious_direction.data.pluck(:id)
      assert_not_includes malicious_direction.data.to_sql, 'pg_sleep'
      assert_equal 'created_at', FilterService.sort_column(sort: 'application_date')
      assert_equal 'desc', FilterService.sort_direction(sort: 'status')
    end

    test 'sorts applicant names case insensitively with a stable first name tie break' do
      zebra = create(:application, user: create(:constituent, last_name: 'zebra', first_name: 'Alex'))
      zoe = create(:application, user: create(:constituent, last_name: 'Alpha', first_name: 'Zoe'))
      jamie = create(:application, user: create(:constituent, last_name: 'alpha', first_name: 'Jamie'))
      scope = Application.where(id: [zebra.id, zoe.id, jamie.id])

      assert_equal [jamie.id, zoe.id, zebra.id],
                   FilterService.new(scope, sort: 'applicant').apply_filters.data.pluck(:id)
      assert_equal [zebra.id, zoe.id, jamie.id],
                   FilterService.new(scope, sort: 'user.last_name', direction: 'desc').apply_filters.data.pluck(:id)
    end

    test 'status duration uses the latest lifecycle entry and sorts unknown dates last in either direction' do
      @active_app = create(:application, created_at: 60.days.ago, user: create(:constituent, speech_disability: true))
      assert_predicate @active_app.reload.user, :disability_selected?
      travel_to(40.days.ago) { @active_app.transition_status!(:awaiting_proof, actor: @guardian) }
      travel_to(35.days.ago) { @active_app.transition_status!(:in_progress, actor: @guardian) }
      latest_entry = 31.days.ago.change(usec: 0)
      travel_to(latest_entry) { @active_app.transition_status!(:awaiting_proof, actor: @guardian) }
      Current.set(user: @active_app.user) { @active_app.update!(alternate_contact_name: 'Routine edit') }
      @active_app.transition_status!(:awaiting_proof, actor: @guardian)

      approval_time = 50.days.ago.change(usec: 0)
      @approved_app.status_changes.create!(from_status: 'in_progress', to_status: 'approved', changed_at: approval_time)
      @approved_app.status_changes.create!(from_status: 'not_reviewed', to_status: 'approved', change_type: :proof, changed_at: 1.day.ago,
                                           metadata: { change_type: 'proof' })
      @approved_app.status_changes.create!(from_status: 'received', to_status: 'approved', change_type: :disability_certification,
                                           changed_at: 1.hour.ago, metadata: { change_type: 'disability_certification' })
      scope = Application.where(id: [@active_app.id, @approved_app.id, @dependent_app.id])

      longest_first = FilterService.new(scope, sort: 'status').apply_filters.data.to_a
      assert_equal [@approved_app.id, @active_app.id, @dependent_app.id], longest_first.map(&:id)
      assert_equal approval_time, longest_first.first.current_status_entered_at
      assert_equal latest_entry, longest_first.second.current_status_entered_at
      assert_nil longest_first.last.current_status_entered_at
      assert_equal [@active_app.id, @approved_app.id, @dependent_app.id],
                   FilterService.new(scope, sort: 'status', direction: 'asc').apply_filters.data.pluck(:id)
    end

    test 'creation supplies status age only for known initial draft and paper intake states' do
      @draft_app.update!(created_at: 45.days.ago)
      paper = create(:application, status: :awaiting_proof, submission_method: :paper, created_at: 31.days.ago)
      scope = Application.where(id: [@draft_app.id, paper.id, @active_app.id, @approved_app.id])
      rows = FilterService.with_list_details(scope).index_by(&:id)

      assert_equal @draft_app.created_at, rows.fetch(@draft_app.id).current_status_entered_at
      assert_equal paper.created_at, rows.fetch(paper.id).current_status_entered_at
      assert_nil rows.fetch(@active_app.id).current_status_entered_at
      assert_nil rows.fetch(@approved_app.id).current_status_entered_at
    end

    test 'next action labels and sorting share actionable proof and certification state' do
      proof = create(:application, :with_residency_proof)
      certification = create(:application, :with_disability_certification, income_proof_status: :approved,
                                                                           residency_proof_status: :approved, id_proof_status: :approved, disability_certification_status: :received)
      ready = create(:application, income_proof_status: :approved, residency_proof_status: :approved, id_proof_status: :approved,
                                   disability_certification_status: :approved)
      income_not_required = create(:application, :with_income_proof, residency_proof_status: :approved, id_proof_status: :approved)
      income_not_required.update!(income_proof_required: false)
      scope = Application.where(id: [proof.id, certification.id, ready.id, income_not_required.id, @active_app.id, @approved_app.id])
      result = FilterService.new(scope, sort: 'next_action').apply_filters.data
      rows = result.index_by(&:id)

      assert_predicate proof, :proof_review_pending?
      assert_equal 'Review proof', rows.fetch(proof.id).next_action
      assert_equal 'Review certification', rows.fetch(certification.id).next_action
      assert_predicate ready, :required_proofs_approved?
      assert_equal 'Review application', rows.fetch(ready.id).next_action
      assert_not income_not_required.proof_review_pending?
      assert_equal 'Open application', rows.fetch(income_not_required.id).next_action
      assert_equal 'Open application', rows.fetch(@active_app.id).next_action, 'A missing file cannot be reviewed'
      assert_equal 'Open application', rows.fetch(@approved_app.id).next_action, 'Approved applications are outside the review queue'
      assert_equal ['Open application', 'Open application', 'Open application', 'Review application', 'Review certification', 'Review proof'],
                   result.map(&:next_action)
      assert_equal ['Review proof', 'Review certification', 'Review application', 'Open application', 'Open application', 'Open application'],
                   FilterService.new(scope, sort: 'next_action', direction: 'desc').apply_filters.data.map(&:next_action)
    end

    test 'list projection retains filtered joins and supports filtering its approval timestamp alias' do
      application = create(:application, user: create(:constituent, first_name: 'Projection', speech_disability: true))
      application.status_changes.create!(from_status: 'draft', to_status: 'in_progress', changed_at: 31.days.ago)
      assert @scope.joins(:user).exists?(id: application.id), 'The search joins an actual constituent applicant'
      result = FilterService.new(@scope, q: application.user.first_name).apply_filters

      assert result.success?
      assert_equal [application.id], result.data.where(current_status_entered_at: 32.days.ago..).pluck(:id)
      assert_equal 1, result.data.where(current_status_entered_at: 32.days.ago..).count
      assert_empty result.data.where(current_status_entered_at: 30.days.ago..)
    end

    test 'supports the additional recent creation date windows' do
      @active_app.update!(created_at: 50.days.ago)
      @approved_app.update!(created_at: 100.days.ago)
      @draft_app.update!(created_at: 13.months.ago)
      scope = Application.where(id: [@active_app.id, @approved_app.id, @draft_app.id])

      assert_equal [@active_app.id], FilterService.new(scope, date_range: 'last_60').apply_filters.data.pluck(:id)
      assert_equal [@active_app.id, @approved_app.id], FilterService.new(scope, date_range: 'last_120').apply_filters.data.pluck(:id)
      assert_equal [@active_app.id, @approved_app.id], FilterService.new(scope, date_range: 'last_12_months').apply_filters.data.pluck(:id)
    end

    test 'handles errors gracefully' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with('Error applying filters: StandardError').once

      with_mocked_attachments do
        bad_scope = Object.new
        def bad_scope.where(*_args)
          raise StandardError, 'Test error'
        end

        # The status parameter sends where directly to the supplied scope.
        service = FilterService.new(bad_scope, { status: 'draft' })

        service_result = service.apply_filters

        assert service_result.failure?, 'Expected service call to fail'
        assert_equal bad_scope, service_result.data, 'Expected data to be the original scope on failure'
        assert_equal 'Error applying filters: Test error', service_result.message
      end
    end
  end
end
