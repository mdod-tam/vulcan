# frozen_string_literal: true

require 'test_helper'

module Applications
  class ApplicationCreatorTest < ActiveSupport::TestCase
    setup do
      @timestamp = Time.current.to_f.to_s.gsub('.', '')
      @user = create_user
      @dependent = create_dependent_for(@user)
    end

    test "creates application with valid form" do
      form = create_valid_form(@user)
      
      result = ApplicationCreator.call(form)
      
      assert result.success?
      assert_not_nil result.application
      assert result.application.persisted?
      assert_equal @user, result.application.user
      assert_equal 50000.0, result.application.annual_income.to_f
    end

    test "updates existing application" do
      application = create_application_for(@user)
      form = create_form_with_application(@user, application)
      
      result = ApplicationCreator.call(form)
      
      assert result.success?
      assert_equal application, result.application
      assert_equal 60000.0, result.application.annual_income.to_f
    end

    test "creates dependent application with guardian relationship" do
      create_guardian_relationship(@user, @dependent)
      form = create_valid_dependent_form(@user, @dependent)
      
      result = ApplicationCreator.call(form)
      
      assert result.success?
      assert_equal @dependent, result.application.user
      assert_equal @user, result.application.managing_guardian
    end

    test "updates user attributes" do
      form = create_valid_form(@user)
      form.hearing_disability = true
      form.physical_address_1 = "123 Test St"
      
      ApplicationCreator.call(form)
      
      @user.reload
      assert @user.hearing_disability?
      assert_equal "123 Test St", @user.physical_address_1
    end

    test "sets medical provider details" do
      form = create_valid_form(@user)
      form.medical_provider_name = "Dr. Test"
      form.medical_provider_phone = "555-1234"
      
      result = ApplicationCreator.call(form)
      
      assert_equal "Dr. Test", result.application.medical_provider_name
      assert_equal "555-1234", result.application.medical_provider_phone
    end

    test "logs audit event for creation" do
      form = create_valid_form(@user)
      
      assert_difference 'Event.count', 1 do
        ApplicationCreator.call(form)
      end
      
      audit_event = Event.last
      assert_equal 'application_created', audit_event.action
      assert_equal @user, audit_event.user
    end

    test "logs audit event for update" do
      application = create_application_for(@user)
      form = create_form_with_application(@user, application)
      
      assert_difference 'Event.count', 1 do
        ApplicationCreator.call(form)
      end
      
      audit_event = Event.last
      assert_equal 'application_updated', audit_event.action
    end

    test "handles invalid form" do
      form = ApplicationForm.new(
        current_user: @user,
        submission_method: 'online',
        is_submission: true
        # Form is invalid - missing required fields like annual_income for submission
      )
      
      result = ApplicationCreator.call(form)
      
      assert result.failure?
      assert_includes result.error_messages, "Form is invalid"
    end

    test "handles database errors gracefully" do
      form = create_valid_form(@user)
      # Force a validation error by making annual_income invalid
      form.annual_income = nil
      form.is_submission = true
      
      result = ApplicationCreator.call(form)
      
      assert result.failure?
      assert_not_empty result.error_messages
    end

    test "sets submission status correctly for submissions" do
      form = create_valid_form(@user)
      form.is_submission = true
      
      result = ApplicationCreator.call(form)
      
      assert_equal 'in_progress', result.application.status
    end

    test "sets draft status for non-submissions" do
      form = create_valid_form(@user)
      form.is_submission = false
      
      result = ApplicationCreator.call(form)
      
      assert_equal 'draft', result.application.status
    end

    test "logs dependent application events" do
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
        phone: "555#{@timestamp[-7..-1]}",
        password: 'password123',
        password_confirmation: 'password123',
        type: 'Users::Constituent'
      )
    end

    def create_dependent_for(guardian)
      Users::Constituent.create!(
        email: "dependent#{@timestamp}@example.com",
        first_name: 'Dependent',
        last_name: 'User',
        phone: "556#{@timestamp[-7..-1]}",
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