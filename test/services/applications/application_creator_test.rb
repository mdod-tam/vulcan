# frozen_string_literal: true

require 'test_helper'

module Applications
  class ApplicationCreatorTest < ActiveSupport::TestCase
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
        # Form is invalid - missing required fields like annual_income for submission
      )

      result = ApplicationCreator.call(form)

      assert result.failure?
      assert_includes result.error_messages, 'Form is invalid'
    end

    test 'handles database errors gracefully' do
      form = create_valid_form(@user)
      # Force a validation error by making annual_income invalid
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

    test 'sets draft status for non-submissions' do
      form = create_valid_form(@user)
      form.is_submission = false

      result = ApplicationCreator.call(form)

      assert_equal 'draft', result.application.status
    end

    test 'logs dependent application events' do
      create_guardian_relationship(@user, @dependent)
      form = create_valid_dependent_form(@user, @dependent)

      # Mock the EventService to verify it's called
      mock_service = Minitest::Mock.new
      mock_service.expect :log_dependent_application_update, nil do |args|
        args[:dependent] == @dependent && args[:relationship_type] == 'parent'
      end

      result = nil
      Applications::EventService.stub :new, mock_service do
        result = ApplicationCreator.call(form)
      end

      # Verify the application was created successfully
      assert result.success?
      assert_not_nil result.application
      assert_equal @dependent, result.application.user
      assert_equal @user, result.application.managing_guardian

      mock_service.verify
    end

    private

    def create_user
      Users::Constituent.create!(
        email: "test#{@timestamp}@example.com",
        first_name: 'Test',
        last_name: 'User',
        phone: "555#{@timestamp[-7..]}",
        password: 'password123',
        password_confirmation: 'password123',
        type: 'Users::Constituent'
      )
    end

    def create_dependent_for(_guardian)
      Users::Constituent.create!(
        email: "dependent#{@timestamp}@example.com",
        first_name: 'Dependent',
        last_name: 'User',
        phone: "556#{@timestamp[-7..]}",
        password: 'password123',
        password_confirmation: 'password123',
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
        medical_provider_email: 'provider@test.com'
      )
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
        medical_provider_email: 'provider@test.com'
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
        medical_provider_email: 'updated@test.com'
      )
    end
  end
end
