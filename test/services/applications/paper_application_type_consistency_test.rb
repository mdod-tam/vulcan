# frozen_string_literal: true

require 'test_helper'

module Applications
  class PaperApplicationTypeConsistencyTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @admin = create(:admin)
      @timestamp = Time.current.to_f.to_s.gsub('.', '')

      # Set Current context to skip proof validations in tests
      Current.paper_context = true

      # Set up FPL policies for testing
      setup_fpl_policies
      @valid_params = {
        constituent: {
          first_name: 'John',
          last_name: 'Malone',
          email: "john.malone.#{@timestamp}@example.com",
          phone: "202424#{@timestamp[-4..]}",
          physical_address_1: '12122 long ridge ln',
          city: 'bowie',
          state: 'MD',
          zip_code: '20715',
          cognition_disability: '1'
        },
        application: {
          household_size: '5',
          annual_income: '29999',
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_name: 'doctor',
          medical_provider_phone: '2028321821',
          medical_provider_email: 'doctor@example.com'
        }
      }
    end

    test 'creates constituent with proper Users::Constituent type' do
      NotificationService.stubs(:create_and_deliver!).returns(nil)

      service = PaperApplicationService.new(
        params: @valid_params,
        admin: @admin
      )

      assert service.create, "Failed to create paper application: #{service.errors.join(', ')}"

      # Verify the constituent was created with the right type
      constituent = User.find_by(email: @valid_params[:constituent][:email])
      assert_not_nil constituent, 'Constituent was not created'
      assert_equal 'Users::Constituent', constituent.type, 'Constituent has incorrect type'
    end

    teardown do
      # Clean up Current context after the test
      Current.reset
    end
  end
end
