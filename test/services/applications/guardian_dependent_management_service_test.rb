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
  end
end
