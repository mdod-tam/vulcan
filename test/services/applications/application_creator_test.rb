# frozen_string_literal: true

require 'test_helper'

module Applications
  class ApplicationCreatorTest < ActiveSupport::TestCase
    include ActionDispatch::TestProcess::FixtureFile

    setup do
      @timestamp = Time.current.to_f.to_s.gsub('.', '')
      @user = create_user
      @dependent = create_dependent_for(@user)
    end

    test 'creates application with valid form' do
      form = create_valid_form(@user)

      result = ApplicationCreator.call(form)

      assert result.success?
      assert_not_nil result.application
      assert result.application.persisted?
      assert_equal @user, result.application.user
      assert_equal 50_000.0, result.application.annual_income.to_f
    end

    test 'updates existing application' do
      application = create_application_for(@user)
      form = create_form_with_application(@user, application)

      result = ApplicationCreator.call(form)

      assert result.success?
      assert_equal application, result.application
      assert_equal 60_000.0, result.application.annual_income.to_f
    end

    test 'creates dependent application with guardian relationship' do
      create_guardian_relationship(@user, @dependent)
      form = create_valid_dependent_form(@user, @dependent)

      result = ApplicationCreator.call(form)

      assert result.success?
      assert_equal @dependent, result.application.user
      assert_equal @user, result.application.managing_guardian
    end

    test 'updates an existing dependent application from its locked ownership even when user_id is omitted' do
      create_guardian_relationship(@user, @dependent)
      application = create(
        :application,
        :draft,
        user: @dependent,
        managing_guardian: @user,
        annual_income: '40000'
      )
      form = create_form_with_application(@user, application)

      result = ApplicationCreator.call(form)

      assert result.success?, result.error_messages.inspect
      assert_equal @dependent.id, result.application.user_id
      assert_equal @user.id, result.application.managing_guardian_id
      assert @dependent.reload.vision_disability?
      assert_not @user.reload.vision_disability?
    end

    test 'dependent application rejects a guardian whose locked role is no longer constituent' do
      create_guardian_relationship(@user, @dependent)
      @user.update_column(:type, 'Users::Administrator')
      form = create_valid_dependent_form(User.find(@user.id), @dependent)

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert_includes result.error_messages, 'Only constituent records can use the constituent application portal.'
    end

    test 'dependent application rejects an applicant whose locked role is no longer constituent' do
      create_guardian_relationship(@user, @dependent)
      @dependent.update_column(:type, 'Users::Administrator')
      form = create_valid_dependent_form(@user, User.find(@dependent.id))

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert_includes result.error_messages, 'Only constituent records can use the constituent application portal.'
    end

    test 'submission creates exactly one application_status_changed event' do
      application = create_application_for(@user)
      form = create_form_with_application(@user, application)
      form.is_submission = true

      assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
        result = ApplicationCreator.call(form)
        assert result.success?
      end
    end

    test 'new submitted application logs creation as draft and submission as a separate status change' do
      form = create_valid_form(@user)
      form.is_submission = true

      assert_difference -> { Event.where(action: 'application_created').count }, 1 do
        assert_difference -> { Event.where(action: 'application_status_changed').count }, 1 do
          result = ApplicationCreator.call(form)
          assert result.success?

          creation_event = Event.where(action: 'application_created', auditable: result.application).order(:created_at).last
          status_event = Event.where(action: 'application_status_changed', auditable: result.application).order(:created_at).last

          assert_equal 'draft', creation_event.metadata['initial_status']
          assert_equal 'draft', status_event.metadata['old_status']
          assert_equal 'in_progress', status_event.metadata['new_status']
        end
      end
    end

    test 'updates user attributes' do
      form = create_valid_form(@user)
      form.hearing_disability = true
      form.physical_address_1 = '123 Test St'
      form.locale = 'es'

      ApplicationCreator.call(form)

      @user.reload
      assert @user.hearing_disability?
      assert_equal '123 Test St', @user.physical_address_1
      assert_equal 'es', @user.locale
    end

    test 'sets medical provider details' do
      form = create_valid_form(@user)
      form.medical_provider_name = 'Dr. Test'
      form.medical_provider_phone = '555-1234'

      result = ApplicationCreator.call(form)

      assert_equal 'Dr. Test', result.application.medical_provider_name
      assert_equal '555-1234', result.application.medical_provider_phone
    end

    test 'logs audit event for creation' do
      form = create_valid_form(@user)

      assert_difference 'Event.count', 1 do
        ApplicationCreator.call(form)
      end

      audit_event = Event.last
      assert_equal 'application_created', audit_event.action
      assert_equal @user, audit_event.user
    end

    test 'logs audit event for update' do
      application = create_application_for(@user)
      form = create_form_with_application(@user, application)

      assert_difference 'Event.count', 1 do
        ApplicationCreator.call(form)
      end

      audit_event = Event.last
      assert_equal 'application_updated', audit_event.action
    end

    test 'submission without non-status changes does not log application_updated' do
      application = create(
        :application,
        :draft,
        user: @user,
        annual_income: '40000',
        household_size: 2,
        submission_method: 'online',
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true
      )
      form = ApplicationForm.new(
        current_user: @user,
        application: application,
        annual_income: application.annual_income,
        household_size: application.household_size,
        submission_method: application.submission_method,
        hearing_disability: @user.hearing_disability,
        vision_disability: true,
        speech_disability: @user.speech_disability,
        mobility_disability: @user.mobility_disability,
        cognition_disability: @user.cognition_disability,
        medical_provider_name: application.medical_provider_name,
        medical_provider_phone: application.medical_provider_phone,
        medical_provider_email: application.medical_provider_email,
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true,
        is_submission: true
      )

      assert_no_difference -> { Event.where(action: 'application_updated', auditable: application).count } do
        assert_difference -> { Event.where(action: 'application_status_changed', auditable: application).count }, 1 do
          result = ApplicationCreator.call(form)
          assert result.success?
        end
      end
    end

    test 'handles invalid form' do
      form = ApplicationForm.new(
        current_user: @user,
        submission_method: 'online',
        is_submission: true
      )

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert_includes result.error_messages, 'Form is invalid'
    end

    test 'handles database errors gracefully' do
      form = create_valid_form(@user)
      form.annual_income = nil
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert_not_empty result.error_messages
    end

    test 'sets submission status correctly for submissions' do
      form = create_valid_form(@user)
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert_equal 'in_progress', result.application.status
    end

    test 'submitted online application requires provider info' do
      form = create_valid_form(@user)
      form.is_submission = true
      form.medical_provider_name = nil
      form.medical_provider_phone = nil
      form.medical_provider_email = nil

      Applications::RequestProviderInfo.expects(:new).never

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert_includes result.error_messages, 'Form is invalid'
      assert_includes form.errors[:base], 'Medical provider information is required for submission.'
    end

    test 'sets draft status for non-submissions' do
      form = create_valid_form(@user)
      form.is_submission = false

      result = ApplicationCreator.call(form)

      assert_equal 'draft', result.application.status
    end

    test 'dependent application creation records creation without an update event' do
      create_guardian_relationship(@user, @dependent)
      form = create_valid_dependent_form(@user, @dependent)
      result = nil
      assert_no_difference -> { Event.where(action: 'application_for_dependent_updated').count } do
        assert_difference -> { Event.where(action: 'application_created').count }, 1 do
          result = ApplicationCreator.call(form)
        end
      end

      assert result.success?, result.error_messages.inspect
      event = Event.find_by!(action: 'application_created', auditable: result.application)
      assert_equal @user.id, event.user_id
      assert_equal @dependent.id, result.application.reload.user_id
      assert_equal @user.id, result.application.managing_guardian_id
    end

    test 'dependent application edits record one contextual update instead of a generic update' do
      application = create_dependent_draft
      form = dependent_update_form(application)
      form.annual_income = '60000'

      assert_no_difference -> { Event.where(action: 'application_updated', auditable: application).count } do
        assert_difference -> { dependent_update_events(application).count }, 1 do
          result = ApplicationCreator.call(form)
          assert result.success?, result.error_messages.inspect
        end
      end

      event = dependent_update_events(application).sole
      assert_equal @user.id, event.user_id
      assert_equal @dependent.id, event.metadata['dependent_id']
      assert_equal @user.id, event.metadata['managing_guardian_id']
      assert_equal 'parent', event.metadata['guardian_relationship']
      assert_equal ['application.annual_income'], event.metadata['changed_fields']
      assert_match(/\A[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/, event.metadata['operation_id'])
      assert_equal %w[__service_generated application_id changed_fields dependent_id guardian_relationship
                      managing_guardian_id operation_id timestamp], event.metadata.keys.sort
      assert_equal 60_000, application.reload.annual_income
    end

    test 'dependent-only edits record the persisted applicant change' do
      @dependent.update!(locale: 'en')
      application = create_dependent_draft
      form = dependent_update_form(application)
      form.locale = 'es'

      assert_difference -> { dependent_update_events(application).count }, 1 do
        result = ApplicationCreator.call(form)
        assert result.success?, result.error_messages.inspect
      end

      assert_equal 'es', @dependent.reload.locale
      assert_equal ['dependent.locale'], dependent_update_events(application).sole.metadata['changed_fields']
    end

    test 'unchanged dependent drafts ignore guardian dirt and do not log repeat updates' do
      application = create_dependent_draft
      original_name = @user.first_name
      @user.first_name = 'Unsaved guardian name'

      assert_no_difference -> { dependent_update_events(application).count } do
        2.times do
          result = ApplicationCreator.call(dependent_update_form(application))
          assert result.success?, result.error_messages.inspect
          travel 6.seconds
        end
      end

      assert_equal original_name, @user.reload.first_name
    end

    test 'dependent submission retains field changes before its later lifecycle save' do
      application = create_dependent_draft
      form = dependent_update_form(application)
      form.annual_income = '60000'
      form.locale = 'es'
      form.is_submission = true

      assert_difference -> { dependent_update_events(application).count }, 1 do
        result = ApplicationCreator.call(form)
        assert result.success?, result.error_messages.inspect
      end

      assert_equal 'in_progress', application.reload.status
      assert_equal 60_000, application.annual_income
      assert_equal 'es', @dependent.reload.locale
      assert_equal %w[application.annual_income dependent.locale],
                   dependent_update_events(application).sole.metadata['changed_fields']
    end

    test 'distinct dependent edits inside the audit window retain both events' do
      application = create_dependent_draft

      assert_difference -> { dependent_update_events(application).count }, 2 do
        %w[60000 70000].each do |income|
          form = dependent_update_form(application)
          form.annual_income = income
          result = ApplicationCreator.call(form)
          assert result.success?, result.error_messages.inspect
        end
      end

      assert_equal 70_000, application.reload.annual_income
      operation_ids = dependent_update_events(application).map { |event| event.metadata['operation_id'] }
      assert_equal 2, operation_ids.compact.uniq.size
    end

    test 'dependent update audit records fields without persisting address income or disability values' do
      application = create_dependent_draft
      form = dependent_update_form(application)
      form.annual_income = '60000'
      form.physical_address_1 = '145 Private Lane'
      form.hearing_disability = false
      form.vision_disability = true

      result = ApplicationCreator.call(form)
      assert result.success?, result.error_messages.inspect

      event = dependent_update_events(application).sole
      assert_equal %w[application.annual_income dependent.hearing_disability
                      dependent.physical_address_1 dependent.vision_disability], event.metadata['changed_fields']
      assert_equal %w[__service_generated application_id changed_fields dependent_id guardian_relationship
                      managing_guardian_id operation_id timestamp], event.metadata.keys.sort
      assert_equal '145 Private Lane', @dependent.reload.physical_address_1
      assert_not @dependent.hearing_disability?
      assert_equal 60_000, application.reload.annual_income
    end

    test 'dependent update audit failure rolls back applicant and application changes' do
      application = create_dependent_draft
      application_before = application.reload.attributes
      dependent_before = @dependent.reload.attributes
      form = dependent_update_form(application)
      form.annual_income = '60000'
      form.locale = 'es'
      original_log = AuditEventService.method(:log)
      fail_update_audit = lambda do |**arguments|
        raise 'dependent audit unavailable' if arguments[:action] == 'application_for_dependent_updated'

        original_log.call(**arguments)
      end

      result = nil
      assert_no_difference 'Event.count' do
        AuditEventService.stub(:log, fail_update_audit) { result = ApplicationCreator.call(form) }
      end

      assert result.failure?
      assert_includes result.error_messages, 'dependent audit unavailable'
      assert_equal application_before, application.reload.attributes
      assert_equal dependent_before, @dependent.reload.attributes
    end

    # Pending identity review
    # Final submission waits for staff to resolve the applicant's open registration soft match case.

    test 'blocks final submission while the applicant has an open registration soft match case' do
      open_registration_soft_match_case_for(@user)
      form = create_valid_form(@user)
      form.is_submission = true

      result = nil
      assert_no_difference 'Application.count' do
        result = ApplicationCreator.call(form)
      end

      assert result.failure?
      assert_includes result.error_messages,
                      I18n.t('activemodel.errors.models.application_form.attributes.base.pending_identity_review')
    end

    # ApplicationForm#message_locale selects the applicant's locale when the ambient locale differs.
    test 'the refusal is rendered in the applicant locale, not the ambient one' do
      spanish_user = create(:constituent, locale: 'es')
      open_registration_soft_match_case_for(spanish_user)
      form = create_valid_form(spanish_user)
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.failure?
      expected = I18n.t('activemodel.errors.models.application_form.attributes.base.pending_identity_review',
                        locale: :es)
      assert_includes result.error_messages, expected
      assert_not_includes result.error_messages,
                          I18n.t('activemodel.errors.models.application_form.attributes.base.pending_identity_review',
                                 locale: :en)
    end

    test 'a refused document is named and explained in the applicant locale' do
      spanish_user = create(:constituent, locale: 'es')
      form = create_valid_form_with_proofs(spanish_user)
      form.income_proof = fixture_file_upload('test/fixtures/files/invalid.exe', 'application/octet-stream')

      result = I18n.with_locale(:en) { ApplicationCreator.call(form) }

      assert result.failure?
      assert_includes result.error_messages,
                      "Comprobante de ingresos: #{I18n.t('documents.refused.invalid_type', locale: :es)}"
    end

    test 'a later refused document leaves no stored file behind for an earlier one' do
      form = create_valid_form_with_proofs(@user)
      form.income_proof = fixture_file_upload('test/fixtures/files/invalid.exe', 'application/octet-stream')
      stored_keys = []
      record_upload = ->(*, payload) { stored_keys << payload[:key] }

      result = ActiveSupport::Notifications.subscribed(record_upload, 'service_upload.active_storage') do
        ApplicationCreator.call(form)
      end

      assert result.failure?
      assert_equal 1, stored_keys.size, 'only the residency proof passes the gate and is stored'
      assert_not ActiveStorage::Blob.exists?(key: stored_keys.first)
      assert_not ActiveStorage::Blob.service.exist?(stored_keys.first)
    end

    # Submitted locale values reach the form without an allowlist.
    # An unsupported locale must fall back before I18n receives it, so the gate can return its typed refusal.
    test 'an unsupported submitted locale falls back instead of degrading the refusal' do
      open_registration_soft_match_case_for(@user)
      form = create_valid_form(@user)
      form.locale = 'xx'
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert result.pending_identity_review?,
             'an unsupported locale must not turn the refusal into a generic error'
      assert_includes result.error_messages, pending_identity_review_message
    end

    test 'allows a draft save while the applicant has an open registration soft match case' do
      open_registration_soft_match_case_for(@user)
      form = create_valid_form(@user)
      form.is_submission = false

      result = ApplicationCreator.call(form)

      assert result.success?, result.error_messages.to_sentence
      assert result.application.persisted?
      assert_equal 'draft', result.application.status
    end

    # The refusal notice offers Save Application to retain documents. Draft saves must still reach attachment intake.
    test 'a draft save while gated still attaches the selected documents' do
      open_registration_soft_match_case_for(@user)
      form = create_valid_form_with_proofs(@user)
      form.is_submission = false

      result = ApplicationCreator.call(form)

      assert result.success?, result.error_messages.to_sentence
      application = result.application.reload
      assert application.residency_proof.attached?, 'the recovery the notice promises must work'
      assert application.income_proof.attached?
      assert_equal 'draft', application.status
    end

    test 'an unchanged retry repeats the same refusal and creates no duplicate draft' do
      open_registration_soft_match_case_for(@user)

      first = ApplicationCreator.call(create_valid_form(@user).tap { |f| f.is_submission = true })
      second = nil
      assert_no_difference 'Application.count' do
        second = ApplicationCreator.call(create_valid_form(@user).tap { |f| f.is_submission = true })
      end

      assert first.failure?
      assert second.failure?
      assert_equal first.error_messages, second.error_messages
    end

    test 'does not gate the candidate account named by someone else open case' do
      candidate = create(:constituent)
      open_registration_soft_match_case_for(@user, candidate: candidate)
      form = create_valid_form(candidate)
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.success?, "the candidate must not be gated merely for being matched: #{result.error_messages.to_sentence}"
    end

    test 'does not gate cases from sources other than registration soft match' do
      open_registration_soft_match_case_for(@user, source: :portal_dependent)
      form = create_valid_form(@user)
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.success?, "only registration_soft_match gates submission: #{result.error_messages.to_sentence}"
    end

    test 'allows final submission once the case is resolved' do
      review_case = open_registration_soft_match_case_for(@user)
      review_case.update!(
        status: :resolved_ignored,
        resolution_determination: :keep_separate,
        resolution_rationale: 'confirmed different people',
        resolved_by: create(:admin),
        resolved_at: Time.current
      )
      form = create_valid_form(@user)
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.success?, result.error_messages.to_sentence
    end

    # The dependent is the applicant. An open case for the acting guardian alone does not block submission.
    test 'gates a guardian-managed application when the dependent applicant is the case subject' do
      create_guardian_relationship(@user, @dependent)
      open_registration_soft_match_case_for(@dependent)
      form = create_valid_dependent_form(@user, @dependent)
      form.is_submission = true

      result = nil
      assert_no_difference 'Application.count' do
        result = ApplicationCreator.call(form)
      end

      assert result.failure?, 'the dependent applicant is the case subject, so the submission must be refused'
      assert result.pending_identity_review?
      assert_includes result.error_messages, pending_identity_review_message
    end

    test 'does not gate a dependent application merely because the acting guardian has an open case' do
      create_guardian_relationship(@user, @dependent)
      open_registration_soft_match_case_for(@user)
      form = create_valid_dependent_form(@user, @dependent)
      form.is_submission = true

      result = ApplicationCreator.call(form)

      assert result.success?,
             "only the applicant's own open case gates: #{result.error_messages.to_sentence}"
      assert_equal @dependent, result.application.user
    end

    # The review gate runs before participant updates and application writes.
    # Both entrypoints must preserve the stored applicant and draft.
    # The notification, job, and delivery assertions guard future changes.
    # These tests do not compare those counts with a successful submission.
    test 'a refused create leaves no application, lifecycle, audit, notification, attachment, or delivery trace' do
      open_registration_soft_match_case_for(@user)
      form = create_valid_form_with_proofs(@user)
      form.is_submission = true
      user_before = @user.reload.attributes

      result = nil
      assert_no_difference %w[Application.count ApplicationStatusChange.count Event.count
                              Notification.count ActiveStorage::Attachment.count] do
        assert_no_enqueued_jobs do
          assert_no_emails do
            result = ApplicationCreator.call(form)
          end
        end
      end

      assert result.failure?
      assert result.pending_identity_review?
      assert_equal user_before, @user.reload.attributes,
                   'a refused submission must not write the submitted attributes onto the applicant'
    end

    test 'a refused update leaves the stored draft and its applicant untouched' do
      open_registration_soft_match_case_for(@user)
      application = create_application_for(@user)
      form = create_form_with_application(@user, application)
      form.is_submission = true
      application_before = application.reload.attributes
      user_before = @user.reload.attributes

      result = nil
      assert_no_difference %w[Application.count ApplicationStatusChange.count Event.count
                              Notification.count ActiveStorage::Attachment.count] do
        assert_no_enqueued_jobs do
          assert_no_emails do
            result = ApplicationCreator.call(form)
          end
        end
      end

      assert result.failure?
      assert result.pending_identity_review?
      assert_equal application_before, application.reload.attributes,
                   'the stored draft must not absorb any part of the refused submission'
      assert_equal user_before, @user.reload.attributes
    end

    private

    def create_dependent_draft
      create_guardian_relationship(@user, @dependent)
      result = ApplicationCreator.call(create_valid_dependent_form(@user, @dependent))
      assert result.success?, result.error_messages.inspect
      result.application
    end

    def dependent_update_form(application)
      form = create_valid_dependent_form(@user, @dependent)
      form.application = application
      form
    end

    def dependent_update_events(application)
      Event.where(action: 'application_for_dependent_updated', auditable: application)
    end

    def pending_identity_review_message(locale: I18n.default_locale)
      I18n.t('activemodel.errors.models.application_form.attributes.base.pending_identity_review',
             locale: locale)
    end

    def open_registration_soft_match_case_for(subject, candidate: nil, source: :registration_soft_match)
      review_case = DuplicateReviewCase.create!(
        source: source,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      if candidate
        review_case.duplicate_review_case_candidates.create!(
          candidate_user: candidate, match_reason: 'name_dob', snapshot: {}
        )
      end
      review_case
    end

    def create_user
      Users::Constituent.create!(
        email: "test#{@timestamp}@example.com",
        first_name: 'Test',
        last_name: 'User',
        date_of_birth: Date.new(1980, 1, 15),
        phone: "555#{@timestamp[-7..]}",
        password: 'password1234',
        password_confirmation: 'password1234',
        type: 'Users::Constituent'
      )
    end

    def create_dependent_for(_guardian)
      Users::Constituent.create!(
        email: "dependent#{@timestamp}@example.com",
        first_name: 'Dependent',
        last_name: 'User',
        date_of_birth: Date.new(1980, 1, 15),
        phone: "556#{@timestamp[-7..]}",
        password: 'password1234',
        password_confirmation: 'password1234',
        type: 'Users::Constituent'
      )
    end

    def create_guardian_relationship(guardian, dependent)
      GuardianRelationship.create!(
        guardian_id: guardian.id,
        dependent_id: dependent.id,
        relationship_type: 'parent'
      )
    end

    def create_application_for(user)
      Application.create!(
        user: user,
        annual_income: '40000',
        status: 'draft',
        application_date: Date.current,
        submission_method: 'online'
      )
    end

    def create_valid_form(user)
      ApplicationForm.new(
        current_user: user,
        annual_income: '50000',
        household_size: 2,
        submission_method: 'online',
        hearing_disability: false,
        vision_disability: true,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false,
        medical_provider_name: 'Test Provider',
        medical_provider_phone: '555-1234',
        medical_provider_email: 'provider@test.com',
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true
      )
    end

    # Proof uploads let these assertions detect unintended attachments.
    def create_valid_form_with_proofs(user)
      form = create_valid_form(user)
      form.residency_proof = fixture_file_upload('test/fixtures/files/residency_proof.pdf', 'application/pdf')
      form.income_proof = fixture_file_upload('test/fixtures/files/income_proof.pdf', 'application/pdf')
      form
    end

    def create_valid_dependent_form(guardian, dependent)
      ApplicationForm.new(
        current_user: guardian,
        user_id: dependent.id,
        annual_income: '50000',
        household_size: 3,
        submission_method: 'online',
        hearing_disability: true,
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false,
        medical_provider_name: 'Test Provider',
        medical_provider_phone: '555-1234',
        medical_provider_email: 'provider@test.com',
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true
      )
    end

    def create_form_with_application(user, application)
      ApplicationForm.new(
        current_user: user,
        application: application,
        annual_income: '60000',
        household_size: 2,
        submission_method: 'online',
        hearing_disability: false,
        vision_disability: true,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false,
        medical_provider_name: 'Updated Provider',
        medical_provider_phone: '555-5678',
        medical_provider_email: 'updated@test.com',
        terms_accepted: true,
        information_verified: true,
        medical_release_authorized: true
      )
    end
  end
end
