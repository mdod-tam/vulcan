# frozen_string_literal: true

require 'test_helper'

module Admin
  class ProofReviewsControllerTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: generate(:email))
      sign_in_for_integration_test(@admin)

      @application = create(:application, :in_progress, skip_proofs: true, user: create(:constituent, email: generate(:email)))
      @application.income_proof.attach(
        io: StringIO.new('income proof'),
        filename: 'income-proof.pdf',
        content_type: 'application/pdf'
      )
    end

    test 'create routes through proof review service behavior and updates proof status' do
      assert_difference -> { @application.proof_reviews.count }, 1 do
        post admin_proof_reviews_path, params: {
          application_id: @application.id,
          proof_review: {
            proof_type: 'income',
            status: 'approved'
          }
        }
      end

      assert_redirected_to admin_application_path(@application)
      @application.reload
      assert @application.income_proof_status_approved?
      assert_equal 'approved', @application.proof_reviews.order(:created_at).last.status
    end

    test 'create shows alert when rejected proof resubmission delivery is not confirmed' do
      ProofReviewService.any_instance.stubs(:call).returns(
        BaseService::Result.new(
          true,
          'Income proof rejected successfully.',
          { resubmission_delivered: false }
        )
      )

      post admin_proof_reviews_path, params: {
        application_id: @application.id,
        proof_review: {
          proof_type: 'income',
          status: 'rejected',
          rejection_reason: 'Income documentation is not acceptable.'
        }
      }

      assert_redirected_to admin_application_path(@application)
      assert_equal I18n.t('admin.proof_reviews.create.proof_completed'), flash[:notice]
      assert_equal I18n.t('admin.proof_reviews.create.resubmission_not_delivered'), flash[:alert]
    end
  end
end
