# frozen_string_literal: true

require 'test_helper'

class DisabilityValidationTest < ActiveSupport::TestCase
  setup do
    @constituent = Constituent.create!(
      email: "test_user_#{Time.now.to_i}@example.com",
      password: 'password123',
      first_name: 'Test',
      last_name: 'User'
    )

    @application_params = {
      user: @constituent,
      application_date: Time.zone.today,
      household_size: 1,
      annual_income: 30_000,
      maryland_resident: true,
      self_certify_disability: true,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '1234567890',
      medical_provider_email: 'test@example.com'
    }
  end

  test 'constituent can be created without disability' do
    constituent = Constituent.new(
      email: "test_user_#{Time.now.to_i + 1}@example.com",
      password: 'password123',
      first_name: 'Test',
      last_name: 'User'
    )
    assert constituent.save, 'Constituent should be saved without disability'
  end

  test 'constituent can be changed to admin without disability' do
    constituent = Constituent.create!(
      email: "test_user_#{Time.now.to_i + 2}@example.com",
      password: 'password123',
      first_name: 'Test',
      last_name: 'User'
    )
    constituent.type = 'Admin'
    assert constituent.save, 'Constituent should be changed to admin without disability'
  end

  test 'application can be saved as draft without disability' do
    application = create(:application,
                         user: @constituent,
                         status: :draft,
                         household_size: 1,
                         annual_income: 30_000)
    assert application.save, 'Application should be saved as draft without disability'
  end

  test 'application cannot be submitted without disability' do
    # Ensure no disabilities are selected
    @constituent.update(
      hearing_disability: false,
      vision_disability: false,
      speech_disability: false,
      mobility_disability: false,
      cognition_disability: false
    )

    application = create(:application,
                         user: @constituent,
                         status: :draft,
                         household_size: 1,
                         annual_income: 30_000)
    application.status = 'in_progress'

    assert_not application.save, 'Application should not be submitted without disability'
    assert_includes application.errors.full_messages,
                    'At least one disability must be selected before submitting an application.'
  end

  test 'application can be submitted with one disability selected' do
    # Test each disability type individually
    disability_types = %i[hearing vision speech mobility cognition]

    disability_types.each_with_index do |disability_type, index|
      # Create a new constituent for each disability type to avoid 3-year validation
      constituent = Constituent.create!(
        email: "test_user_#{Time.now.to_i}_#{index}@example.com",
        password: 'password123',
        first_name: 'Test',
        last_name: 'User'
      )

      # Reset all disabilities to false, then set just one disability to true
      constituent.update(
        hearing_disability: disability_type == :hearing,
        vision_disability: disability_type == :vision,
        speech_disability: disability_type == :speech,
        mobility_disability: disability_type == :mobility,
        cognition_disability: disability_type == :cognition
      )

      application = create(:application,
                           user: constituent,
                           status: :draft,
                           household_size: 1,
                           annual_income: 30_000)
      application.status = 'in_progress'

      assert application.save,
             "Application should be submitted with only #{disability_type} disability selected"
    end
  end

  test 'application can be submitted with multiple disabilities selected' do
    # Set multiple disabilities
    @constituent.update(
      hearing_disability: true,
      vision_disability: true,
      speech_disability: false,
      mobility_disability: true,
      cognition_disability: false
    )

    application = create(:application,
                         user: @constituent,
                         status: :draft,
                         household_size: 1,
                         annual_income: 30_000)
    application.status = 'in_progress'

    assert application.save, 'Application should be submitted with multiple disabilities'
  end

  test 'application can be submitted with all disabilities selected' do
    # Set all disabilities
    @constituent.update(
      hearing_disability: true,
      vision_disability: true,
      speech_disability: true,
      mobility_disability: true,
      cognition_disability: true
    )

    application = create(:application,
                         user: @constituent,
                         status: :draft,
                         household_size: 1,
                         annual_income: 30_000)
    application.status = 'in_progress'

    assert application.save, 'Application should be submitted with all disabilities'
  end

  test 'disability_selected? returns true when at least one disability is selected' do
    @constituent.update(
      hearing_disability: false,
      vision_disability: false,
      speech_disability: false,
      mobility_disability: true,
      cognition_disability: false
    )

    assert @constituent.disability_selected?,
           'disability_selected? should return true when at least one disability is selected'
  end

  test 'disabilities returns concise display labels' do
    @constituent.update(
      hearing_disability: true,
      vision_disability: false,
      speech_disability: true,
      mobility_disability: true,
      cognition_disability: false
    )

    assert_equal %w[Hearing Speech Mobility], @constituent.disabilities
  end

  test 'disability_selected? returns false when no disabilities are selected' do
    @constituent.update(
      hearing_disability: false,
      vision_disability: false,
      speech_disability: false,
      mobility_disability: false,
      cognition_disability: false
    )

    assert_not @constituent.disability_selected?,
               'disability_selected? should return false when no disabilities are selected'
  end
end
