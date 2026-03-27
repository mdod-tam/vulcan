# frozen_string_literal: true

require 'test_helper'

module Admin
  class AdultSearchFeaturesTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin, email: generate(:email))
      ENV['TEST_USER_ID'] = @admin.id.to_s
      sign_in_for_integration_test(@admin)
      assert_authenticated(@admin)
      setup_paper_application_context
    end

    teardown do
      teardown_paper_application_context
    end

    # --- adult_application_context endpoint ---

    test 'adult_application_context returns user profile and eligibility' do
      constituent = create(:constituent, email: generate(:email), city: 'Baltimore', state: 'MD')

      get adult_application_context_admin_user_path(constituent), headers: default_headers, as: :json
      assert_response :success

      json = response.parsed_body
      assert json['success']
      assert_equal constituent.first_name, json.dig('user', 'first_name')
      assert_equal constituent.email, json.dig('user', 'email')
      assert json.key?('eligible_now')
      assert json.key?('product_names')
    end

    test 'adult_application_context returns not found for non-candidate user' do
      staff = create(:admin, email: generate(:email))

      get adult_application_context_admin_user_path(staff), headers: default_headers, as: :json
      assert_response :not_found

      json = response.parsed_body
      assert_equal false, json['success']
    end

    test 'adult_application_context marks ineligible with active application' do
      original_skip = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = true

      begin
        constituent = create(:constituent, email: generate(:email))
        create(:application, :in_progress, user: constituent)

        get adult_application_context_admin_user_path(constituent), headers: default_headers, as: :json
        assert_response :success

        json = response.parsed_body
        assert_equal false, json['eligible_now']
        assert_equal 'active_application', json['ineligibility_reason']
        assert_nil json['eligible_after']
      ensure
        Application.skip_wait_period_validation = original_skip
      end
    end

    test 'adult_application_context sets eligible_after only for waiting period' do
      original_skip = Application.skip_wait_period_validation
      Application.skip_wait_period_validation = false

      begin
        constituent = create(:constituent, email: generate(:email))
        create(:application, :rejected, user: constituent, application_date: 1.year.ago)

        get adult_application_context_admin_user_path(constituent), headers: default_headers, as: :json
        assert_response :success

        json = response.parsed_body
        assert_equal false, json['eligible_now']
        assert_equal 'waiting_period', json['ineligibility_reason']
        assert json['eligible_after'].present?
      ensure
        Application.skip_wait_period_validation = original_skip
      end
    end

    # --- search endpoint with role=constituent ---

    test 'search filters by constituent role when passed' do
      constituent = create(:constituent, email: generate(:email), first_name: 'UniqueSearchName')
      admin_user = create(:admin, email: generate(:email), first_name: 'UniqueSearchName')

      get search_admin_users_path(q: 'UniqueSearchName', role: 'constituent', frame_id: 'adult_search_results'),
          headers: default_headers
      assert_response :success

      assert_match constituent.full_name, response.body
      assert_no_match admin_user.email, response.body
    end

    test 'search includes legacy Constituent STI type rows' do
      legacy = create(:constituent, email: generate(:email), first_name: 'LegacyStiSearchXyz')
      legacy.update_column(:type, 'Constituent')

      get search_admin_users_path(q: 'LegacyStiSearchXyz', role: 'constituent', frame_id: 'adult_search_results'),
          headers: default_headers
      assert_response :success

      assert_match legacy.full_name, response.body
    end

    test 'search role constituent excludes non-constituent users even with prior applications' do
      evaluator = create(:evaluator, email: generate(:email), first_name: 'PaperCandEvalX', hearing_disability: true)
      create(:application, :archived, user: evaluator)

      get search_admin_users_path(q: 'PaperCandEvalX', role: 'constituent', frame_id: 'adult_search_results'),
          headers: default_headers
      assert_response :success

      assert_no_match evaluator.full_name, response.body
    end

    test 'adult_application_context returns not found for non-constituent with applicant history' do
      evaluator = create(:evaluator, email: generate(:email), hearing_disability: true)
      create(:application, :archived, user: evaluator)

      get adult_application_context_admin_user_path(evaluator), headers: default_headers, as: :json
      assert_response :not_found

      json = response.parsed_body
      assert_equal false, json['success']
    end

    # --- compute_applicant_type normalization ---

    test 'applicant_type guardian without guardian_id normalizes to self' do
      controller = Admin::PaperApplicationsController.new
      permitted = { applicant_type: 'guardian', guardian_id: nil, dependent_id: nil }.with_indifferent_access

      result = controller.send(:compute_applicant_type, permitted)
      assert_equal 'self', result
    end

    test 'applicant_type self passes through' do
      controller = Admin::PaperApplicationsController.new
      permitted = { applicant_type: 'self', guardian_id: nil, dependent_id: nil }.with_indifferent_access

      result = controller.send(:compute_applicant_type, permitted)
      assert_equal 'self', result
    end
  end
end
