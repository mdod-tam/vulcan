# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ApplicationsDisabilityTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      # FPL policies drive the income validation.
      setup_fpl_policies

      @constituent = create(:constituent)
      sign_in_for_integration_test(@constituent)

      @application_params = {
        application: {
          household_size: 2,
          annual_income: '18000', # below the eligibility ceiling for a household of 2 (federal poverty level times the policy modifier)
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '555-123-4567',
            email: 'dr.smith@example.com'
          },
          **proof_receipts,
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1',
          # no disabilities selected by default
          hearing_disability: '0',
          vision_disability: '0',
          speech_disability: '0',
          mobility_disability: '0',
          cognition_disability: '0'
        }
      }
    end

    test 'should not create application when submitting with no disabilities' do
      @constituent.update(
        hearing_disability: false,
        vision_disability: false,
        speech_disability: false,
        mobility_disability: false,
        cognition_disability: false
      )

      assert_no_difference 'Application.count' do
        post constituent_portal_applications_path, params: @application_params.merge(submit_application: true)
      end

      assert_response :unprocessable_content
      assert_match(/At least one disability must be selected/, response.body)
    end

    test 'should create application when submitting with one disability' do
      @application_params[:application][:hearing_disability] = '1'

      assert_difference 'Application.count', 1 do
        post constituent_portal_applications_path, params: @application_params.merge(submit_application: true)
      end

      assert_redirected_to constituent_portal_application_path(Application.last)
      assert @constituent.reload.hearing_disability
      assert_equal 'in_progress', Application.last.status
    end

    test 'should create application when submitting with multiple disabilities' do
      @application_params[:application][:hearing_disability] = '1'
      @application_params[:application][:vision_disability] = '1'
      @application_params[:application][:mobility_disability] = '1'

      assert_difference 'Application.count', 1 do
        post constituent_portal_applications_path, params: @application_params.merge(submit_application: true)
      end

      assert_redirected_to constituent_portal_application_path(Application.last)
      assert @constituent.reload.hearing_disability
      assert @constituent.reload.vision_disability
      assert @constituent.reload.mobility_disability
      assert_equal 'in_progress', Application.last.status
    end

    test 'should save draft application even with no disabilities' do
      assert_difference 'Application.count', 1 do
        post constituent_portal_applications_path, params: @application_params
      end

      assert_redirected_to constituent_portal_application_path(Application.last)
      assert_equal 'draft', Application.last.status
    end

    test 'should update application when adding disabilities' do
      post constituent_portal_applications_path, params: @application_params
      application = Application.last

      put constituent_portal_application_path(application), params: {
        application: {
          hearing_disability: '1',
          vision_disability: '1',
          maryland_resident: '1',
          household_size: 2,
          annual_income: '50000',
          self_certify_disability: '1',
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '555-123-4567',
            email: 'dr.smith@example.com'
          },
          **proof_receipts,
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1'
        },
        submit_application: true
      }

      assert_redirected_to constituent_portal_application_path(application)
      assert @constituent.reload.hearing_disability
      assert @constituent.reload.vision_disability
      assert_equal 'in_progress', application.reload.status
    end

    test 'should properly process all disability types' do
      disability_types = %i[hearing vision speech mobility cognition]

      disability_types.each_with_index do |disability_type, index|
        # A unique constituent avoids the 3-year duplicate-application validation.
        constituent = create(:constituent,
                             email: "disability_test_#{Time.now.to_i}_#{index}@example.com")
        sign_in_for_integration_test(constituent)

        constituent.update(
          hearing_disability: disability_type == :hearing,
          vision_disability: disability_type == :vision,
          speech_disability: disability_type == :speech,
          mobility_disability: disability_type == :mobility,
          cognition_disability: disability_type == :cognition
        )

        params = @application_params.deep_dup
        params[:application].merge!(proof_receipts(user: constituent))
        params[:application]["#{disability_type}_disability"] = '1'

        assert_difference 'Application.count', 1 do
          post constituent_portal_applications_path, params: params.merge(submit_application: true)
        end

        created_application = constituent.applications.order(created_at: :desc).first
        assert_redirected_to constituent_portal_application_path(created_application)
        assert constituent.reload.send("#{disability_type}_disability"),
               "#{disability_type}_disability should be true after submission"
      end
    end

    test 'should handle disability validation when transitioning from draft to submitted' do
      post constituent_portal_applications_path, params: @application_params
      application = Application.last
      assert_equal 'draft', application.status

      put constituent_portal_application_path(application), params: {
        application: {
          household_size: 3,
          maryland_resident: '1',
          annual_income: '50000',
          self_certify_disability: '1',
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '555-123-4567',
            email: 'dr.smith@example.com'
          },
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1'
        },
        submit_application: true
      }

      assert_response :unprocessable_content
      assert_match(/At least one disability must be selected/, response.body)

      put constituent_portal_application_path(application), params: {
        application: {
          household_size: 3,
          maryland_resident: '1',
          annual_income: '50000',
          self_certify_disability: '1',
          cognition_disability: '1',
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '555-123-4567',
            email: 'dr.smith@example.com'
          },
          **proof_receipts,
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1'
        },
        submit_application: true
      }

      assert_redirected_to constituent_portal_application_path(application)
      assert @constituent.reload.cognition_disability
      assert_equal 'in_progress', application.reload.status
    end

    private

    def proof_receipts(user: @constituent)
      %i[income_proof residency_proof].to_h do |slot|
        blob = scanned_upload(fixture_file_upload("#{slot}.pdf", 'application/pdf'), user: user, slot: slot.to_s)
        [slot, blob.signed_id]
      end
    end
  end
end
