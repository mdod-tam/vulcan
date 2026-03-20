# frozen_string_literal: true

require 'test_helper'

module Applications
  class ExistingAdultApplicantTest < ActiveSupport::TestCase
    setup do
      setup_paper_application_context
      @admin = create(:admin)
      @constituent = create(:constituent,
                            email: "existing_adult_#{SecureRandom.hex(4)}@example.com",
                            phone: '555-100-2000',
                            physical_address_1: '123 Main St',
                            city: 'Baltimore',
                            state: 'MD',
                            zip_code: '21201')
    end

    teardown do
      teardown_paper_application_context
    end

    test 'process_existing_self_applicant sets constituent without creating new user' do
      service_params = build_existing_adult_params(@constituent)
      service = PaperApplicationService.new(params: service_params, admin: @admin)

      assert_no_difference 'User.count' do
        result = service.send(:process_constituent)
        assert result, "Expected process_constituent to succeed but got errors: #{service.errors.join(', ')}"
      end

      assert_equal @constituent.id, service.constituent.id
    end

    test 'process_existing_self_applicant rejects constituent with active application' do
      original_skip = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = true

      begin
        create(:application, :in_progress, user: @constituent)
        service_params = build_existing_adult_params(@constituent)
        service = PaperApplicationService.new(params: service_params, admin: @admin)

        result = service.send(:process_constituent)
        assert_not result
        assert(service.errors.any? { |e| e.include?('active') || e.include?('pending') })
      ensure
        Application.skip_wait_period_validation = original_skip
      end
    end

    test 'process_existing_self_applicant checks waiting period' do
      original_skip = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = false

      begin
        create(:application, :rejected, user: @constituent, application_date: 1.year.ago)
        service_params = build_existing_adult_params(@constituent)
        service = PaperApplicationService.new(params: service_params, admin: @admin)

        result = service.send(:process_constituent)
        assert_not result
        assert(service.errors.any? { |e| e.include?('eligible') || e.include?('Eligible') })
      ensure
        Application.skip_wait_period_validation = original_skip
      end
    end

    test 'process_existing_self_applicant updates contact info with audit trail' do
      new_email = "updated_#{SecureRandom.hex(4)}@example.com"
      service_params = build_existing_adult_params(@constituent, email: new_email)
      service = PaperApplicationService.new(params: service_params, admin: @admin)

      assert_difference -> { Event.where(action: 'constituent_contact_updated').count }, 1 do
        result = service.send(:process_constituent)
        assert result, "Expected success but got errors: #{service.errors.join(', ')}"
      end

      @constituent.reload
      assert_equal new_email, @constituent.email

      contact_event = Event.where(action: 'constituent_contact_updated').order(:id).last
      assert_equal @admin, contact_event.user
      assert_equal 'paper_application', contact_event.metadata['source']
      assert contact_event.metadata['changes'].key?('email')
    end

    test 'process_existing_self_applicant rejects non-candidate user id' do
      staff = create(:admin, email: generate(:email))
      params = build_existing_adult_params(@constituent).merge(existing_constituent_id: staff.id)
      service = PaperApplicationService.new(params: params, admin: @admin)

      assert_not service.send(:process_constituent)
      assert(service.errors.any? { |e| e.include?('not eligible') })
    end

    test 'process_existing_self_applicant requires contact verification when existing id present' do
      params = build_existing_adult_params(@constituent).merge(contact_info_verified: '0')
      service = PaperApplicationService.new(params: params, admin: @admin)

      assert_not service.send(:process_constituent)
      assert(service.errors.any? { |e| e.include?('Verify contact') })
    end

    test 'process_existing_self_applicant skips contact updates when contact_info_mode is on_file' do
      new_email = "should_not_save_#{SecureRandom.hex(4)}@example.com"
      service_params = build_existing_adult_params(@constituent, email: new_email).merge(
        contact_info_mode: 'on_file',
        contact_info_verified: '1'
      )
      service = PaperApplicationService.new(params: service_params, admin: @admin)

      assert_no_difference -> { Event.where(action: 'constituent_contact_updated').count } do
        result = service.send(:process_constituent)
        assert result, "Expected success but got errors: #{service.errors.join(', ')}"
      end

      @constituent.reload
      assert_not_equal new_email, @constituent.email
    end

    test 'process_existing_self_applicant skips update when no contact changes' do
      # Submit with same data as on file
      service_params = build_existing_adult_params(@constituent, email: @constituent.email, phone: @constituent.phone)
      service = PaperApplicationService.new(params: service_params, admin: @admin)

      assert_no_difference -> { Event.where(action: 'constituent_contact_updated').count } do
        result = service.send(:process_constituent)
        assert result
      end
    end

    test 'existing_self_applicant_scenario detects existing_constituent_id' do
      service = PaperApplicationService.new(
        params: { existing_constituent_id: @constituent.id, applicant_type: 'self' }.with_indifferent_access,
        admin: @admin
      )
      assert service.send(:existing_self_applicant_scenario?, @constituent.id.to_s)
    end

    test 'existing_self_applicant_scenario ignores when applicant_type is dependent' do
      service = PaperApplicationService.new(
        params: { existing_constituent_id: @constituent.id, applicant_type: 'dependent' }.with_indifferent_access,
        admin: @admin
      )
      assert_not service.send(:existing_self_applicant_scenario?, @constituent.id.to_s)
    end

    private

    def build_existing_adult_params(constituent, overrides = {})
      constituent_attrs = {
        first_name: constituent.first_name,
        last_name: constituent.last_name,
        email: overrides[:email] || constituent.email,
        phone: overrides[:phone] || constituent.phone,
        physical_address_1: constituent.physical_address_1,
        city: constituent.city,
        state: constituent.state,
        zip_code: constituent.zip_code,
        date_of_birth: constituent.date_of_birth
      }

      {
        existing_constituent_id: constituent.id,
        applicant_type: 'self',
        contact_info_mode: 'update',
        contact_info_verified: '1',
        constituent: constituent_attrs,
        application: {
          household_size: 1,
          annual_income: 10_000,
          maryland_resident: true,
          self_certify_disability: true,
          medical_provider_name: 'Dr. Test',
          medical_provider_phone: '555-111-2222',
          medical_provider_email: 'test@test.com'
        }
      }.with_indifferent_access
    end
  end
end
