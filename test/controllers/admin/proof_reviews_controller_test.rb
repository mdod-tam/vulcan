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
          { resubmission_delivered: false, warning: 'The proof review was saved, but a follow-up step did not finish.' }
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
      assert_equal "The proof review was saved, but a follow-up step did not finish. #{I18n.t('admin.proof_reviews.create.resubmission_not_delivered')}",
                   flash[:alert]
    end

    test 'a rolled-back reconciliation renders the review form without saving a review' do
      error = 'reconciliation failed <script>capture_payload()</script>'
      Application.any_instance.stubs(:reconcile_workflow_state!).raises(StandardError, error)

      assert_no_difference -> { @application.proof_reviews.count } do
        post admin_proof_reviews_path, params: {
          application_id: @application.id,
          proof_review: { proof_type: 'income', status: 'approved' }
        }
      end

      assert_response :unprocessable_content
      assert_equal 'not_reviewed', @application.reload.income_proof_status
      assert_select '[data-testid="flash-alert"]', text: "Proof review failed: #{error}"
      assert_includes response.body, '&lt;script&gt;capture_payload()&lt;/script&gt;'
      assert_select 'script', text: 'capture_payload()', count: 0
      assert_select "form[action='#{admin_proof_reviews_path(application_id: @application.id)}'][method='post']"
      assert_select 'input[name="proof_review[proof_type]"][value="income"]'
      assert_select 'input[name="proof_review[status]"][value="approved"][checked]'
      assert_select '[data-controller~="proof-review"]', count: 0
      assert_select 'textarea#proof_review_rejection_reason[aria-describedby="proof_review_rejection_reason_help"]'
      assert_select 'input[type="submit"][name="continue"]', count: 0
      assert_select 'input[type="submit"][value="Submit & Exit"]', count: 1
    end

    test 'a rejected review without a reason renders the native reason field and keeps the decision' do
      assert_no_difference -> { @application.proof_reviews.count } do
        post admin_proof_reviews_path, params: {
          application_id: @application.id,
          proof_review: { proof_type: 'income', status: 'rejected', rejection_reason: '' }
        }
      end

      assert_response :unprocessable_content
      assert_equal 'not_reviewed', @application.reload.income_proof_status
      assert_select '[data-testid="flash-alert"]', text: /Rejection reason can't be blank/
      assert_select 'input[name="proof_review[status]"][value="rejected"][checked]'
      assert_select 'label[for="proof_review_rejection_reason"]', text: 'Reason for Rejection (required when rejecting)'
      assert_select '#proof_review_rejection_reason_help', text: /Required when rejecting\. Leave blank when approving\./
      assert_select '.hidden #proof_review_rejection_reason', count: 0
    end

    test 'a rolled-back rejection keeps the submitted reason editable in the native form' do
      Applications::ProofReviewer.any_instance.stubs(:update_application_status).raises(StandardError, 'proof status update failed')
      reason = 'The income document has no applicant name.'

      assert_no_difference -> { @application.proof_reviews.count } do
        post admin_proof_reviews_path, params: {
          application_id: @application.id,
          proof_review: { proof_type: 'income', status: 'rejected', rejection_reason: reason }
        }
      end

      assert_response :unprocessable_content
      assert_equal 'not_reviewed', @application.reload.income_proof_status
      assert_select '[data-testid="flash-alert"]', text: 'Proof review failed: proof status update failed'
      assert_select "form[action='#{admin_proof_reviews_path(application_id: @application.id)}'][method='post']"
      assert_select 'input[name="proof_review[status]"][value="rejected"][checked]'
      assert_select '#proof_review_rejection_reason', text: reason
      assert_select '.hidden #proof_review_rejection_reason', count: 0
    end

    test 'create says the resubmission email was turned off rather than undeliverable' do
      ProofReviewService.any_instance.stubs(:call).returns(
        BaseService::Result.new(true, 'Income proof rejected successfully.',
                                { resubmission_delivered: false, resubmission_suppressed: true })
      )

      post admin_proof_reviews_path, params: {
        application_id: @application.id,
        proof_review: { proof_type: 'income', status: 'rejected', rejection_reason: 'Income documentation is not acceptable.' }
      }

      assert_equal I18n.t('admin.proof_reviews.create.resubmission_suppressed', locale: :en), flash[:alert]
    end
  end

  # Request outcomes must reflect real commits and after-commit callbacks.
  class ProofReviewCommitResponsesTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper
    include ConcurrencyTestHelper

    self.use_transactional_tests = false

    setup do
      @admin = create(:admin, email: generate(:email))
      @user = create(:constituent, email: generate(:email))
      sign_in_for_integration_test(@admin)
      @application = create(:application, :in_progress, :income_not_required, user: @user)
      @application.residency_proof.attach(io: StringIO.new('residency proof'), filename: 'residency.pdf', content_type: 'application/pdf')
      @application.id_proof.attach(io: StringIO.new('ID proof'), filename: 'id.pdf', content_type: 'application/pdf')
      @application.update!(id_proof_status: :approved, medical_certification_status: :approved)
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit failed')
    end

    teardown do
      cleanup_duplicate_review_test_data!(@user, @admin)
      Current.reset
    end

    %i[html turbo_stream].each do |format|
      test "#{format} create shows a warning for a saved review whose callback failed" do
        post_review(format)

        assert_redirected_to admin_application_path(@application)
        assert_equal I18n.t('admin.proof_reviews.create.proof_completed'), flash[:notice]
        assert_match(/review was saved.*follow-up step/, flash[:alert])
        assert_saved_review
        assert @application.events.exists?(action: 'proof_review_follow_up_failed')
      end

      test "#{format} create redirects to the application when saved state cannot be confirmed" do
        ProofReview.stubs(:find_by).raises(ActiveRecord::ConnectionNotEstablished, 'verification unavailable')

        post_review(format)

        assert_response :see_other
        assert_redirected_to admin_application_path(@application)
        assert_match(/may have been saved.*could not be confirmed/, flash[:alert])
        assert_match(/before reviewing it again/, flash[:alert])
        assert_nil flash[:notice]
        assert_saved_review
        assert_not @application.events.exists?(action: 'proof_review_follow_up_failed')
      end
    end

    private

    def post_review(format)
      post admin_proof_reviews_path(format: format), params: {
        application_id: @application.id,
        proof_review: { proof_type: 'residency', status: 'approved' }
      }
    end

    def assert_saved_review
      review = @application.proof_reviews.where(proof_type: :residency, status: :approved).sole
      assert_equal @admin, review.admin
      assert_equal 'approved', @application.reload.residency_proof_status
      assert_equal 'approved', @application.status
      assert @application.status_changes.exists?(from_status: 'in_progress', to_status: 'approved', user: @admin)
      assert @application.events.exists?(action: 'application_status_changed')
    end
  end
end
