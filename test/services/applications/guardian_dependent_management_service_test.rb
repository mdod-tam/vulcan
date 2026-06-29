# frozen_string_literal: true

require 'test_helper'

module Applications
  class GuardianDependentManagementServiceTest < ActiveSupport::TestCase
    setup do
      @guardian = create(:constituent, email: 'guardian@example.com', phone: '410-555-0100')
    end

    test 'process_guardian_scenario returns failure result when guardian information is missing' do
      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        nil,
        {},
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert_not result.success?
      assert_equal 'Failed to setup guardian', result.message
      assert_includes result.data[:errors], 'Guardian information missing'
      assert_includes service.errors, 'Guardian information missing'
    end

    test 'process_guardian_scenario returns failure result when guardian id is invalid' do
      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        -1,
        {},
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert_not result.success?
      assert_equal 'Failed to setup guardian', result.message
      assert_includes result.data[:errors], 'Guardian not found'
    end

    test 'process_guardian_scenario returns failure result when relationship type is missing' do
      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        @guardian.id,
        {},
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        nil
      )

      assert_not result.success?
      assert_equal 'Failed to create relationship', result.message
      assert(result.data[:errors].any? { |error| error.include?('Relationship type required') })
    end

    test 'guardian phone strategy creates unique synthetic primary phone' do
      SecureRandom
        .stubs(:random_number)
        .with(GuardianDependentManagementService::SYNTHETIC_PHONE_RANDOM_SPACE)
        .returns(42)

      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        @guardian.id,
        {},
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert result.success?, "Expected dependent creation to succeed: #{result.data[:errors]}"
      dependent = result.data[:dependent]
      assert_equal '000-000-0042', dependent.phone
      assert_equal @guardian.phone, dependent.dependent_phone
    end

    test 'guardian phone strategy skips occupied synthetic primary phone' do
      create(:constituent, phone: '000-000-0000')
      SecureRandom
        .stubs(:random_number)
        .with(GuardianDependentManagementService::SYNTHETIC_PHONE_RANDOM_SPACE)
        .returns(0, 1)

      service = GuardianDependentManagementService.new(
        email_strategy: 'guardian',
        phone_strategy: 'guardian',
        address_strategy: 'dependent'
      )

      result = service.process_guardian_scenario(
        @guardian.id,
        {},
        { first_name: 'Child', last_name: 'User', date_of_birth: '2015-01-01', hearing_disability: true },
        'Parent'
      )

      assert result.success?, "Expected dependent creation to succeed: #{result.data[:errors]}"
      assert_equal '000-000-0001', result.data[:dependent].phone
    end
  end
end
