# frozen_string_literal: true

require 'test_helper'

module Admin
  class ApplicationsTurboStreamTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @admin = create(:admin, email: generate(:email))
      sign_in_for_integration_test(@admin)
      @application = create(:application, :in_progress, user: create(:constituent, email: generate(:email)))
    end

    def attach_income_proof!
      @application.income_proof.attach(io: file_fixture('income_proof.pdf').open, filename: 'income.pdf', content_type: 'application/pdf')
      DocumentScanFixtures.clear!(@application.income_proof.blob, user: @admin, slot: 'income_proof', fixture: 'income_proof.pdf')
    end

    test 'approve income proof responds with turbo redirect when workflow state may change' do
      attach_income_proof!

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'approved' },
            as: :turbo_stream

      assert_response :see_other
      assert_redirected_to admin_application_path(@application)
      assert_equal 'approved', @application.reload.income_proof_status
      assert_equal @admin, @application.proof_reviews.find_by!(proof_type: :income, status: :approved).admin
      event = Event.find_by!(action: 'proof_approved', auditable: @application)
      assert_equal @admin.id, event.user_id
      assert_equal 'income', event.metadata['proof_type']
    end

    test 'reject income proof responds with turbo streams: update modals container and replace attachments' do
      attach_income_proof!
      product = create(:product, name: 'Historical purchasing model')
      AuditEventService.log(action: 'equipment_needs_updated', actor: @admin, auditable: @application,
                            metadata: { changes: { equipment_needs: { old: [], new: [{ product_id: product.id, remaining_quantity: 2 }] } } })

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'rejected', rejection_reason: 'invalid_document', notes: 'Please upload a valid PDF.' },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      # The controller replaces the modals container (closes all modals and regenerates them)
      assert_turbo_stream action: 'update', target: 'modals'
      assert_turbo_stream action: 'update', target: 'attachments-section'
      assert_turbo_stream action: 'update', target: 'audit-logs'
      assert_includes response.body, 'Historical purchasing model'
      assert_includes response.body, '2 devices'
      assert_equal 'rejected', @application.reload.income_proof_status
      review = @application.proof_reviews.find_by!(proof_type: :income, status: :rejected)
      assert_equal @admin, review.admin
      assert_equal 'Please upload a valid PDF.', review.notes
      assert_includes response.body, 'invalid_document'
      event = Event.find_by!(action: 'proof_rejected', auditable: @application)
      assert_equal @admin.id, event.user_id
      assert_equal 'income', event.metadata['proof_type']
    end

    test 'rejected proof turbo response shows alert when resubmission delivery is not confirmed' do
      attach_income_proof!

      ProofReviewService.any_instance.stubs(:call).returns(
        BaseService::Result.new(
          true,
          'Income proof rejected successfully.',
          { resubmission_delivered: false }
        )
      )

      patch update_proof_status_admin_application_path(@application),
            params: {
              proof_type: 'income',
              status: 'rejected',
              rejection_reason: 'Income documentation is not acceptable.'
            },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type
      assert_includes response.body, I18n.t('admin.proof_reviews.create.resubmission_not_delivered')
    end

    test 'approve residency proof responds with turbo redirect when workflow state may change' do
      # Attach residency proof and keep income untouched
      @application.residency_proof.attach(io: file_fixture('residency_proof.pdf').open, filename: 'residency.pdf', content_type: 'application/pdf')
      DocumentScanFixtures.clear!(@application.residency_proof.blob, user: @admin, slot: 'residency_proof', fixture: 'residency_proof.pdf')

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'residency', status: 'approved' },
            as: :turbo_stream

      assert_response :see_other
      assert_redirected_to admin_application_path(@application)
      assert_equal 'approved', @application.reload.residency_proof_status
      assert_equal @admin, @application.proof_reviews.find_by!(proof_type: :residency, status: :approved).admin
    end

    test 'failed proof review turbo response refreshes flash only' do
      attach_income_proof!

      ProofReviewService.any_instance.stubs(:call).returns(
        BaseService::Result.new(success: false, message: 'Proof review failed: Income proof must be attached.')
      )

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'rejected', rejection_reason: 'invalid_document' },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type
      assert_includes response.body, '<turbo-stream action="update" target="flash">'
      assert_no_match(/target="modals"/, response.body)
      assert_no_match(/target="attachments-section"/, response.body)
    end
  end

  # Request outcomes must reflect real commits and after-commit callbacks.
  class ApplicationProofReviewCommitResponsesTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper
    include ConcurrencyTestHelper

    self.use_transactional_tests = false

    setup do
      @admin = create(:admin, email: generate(:email))
      @user = create(:constituent, email: generate(:email))
      sign_in_for_integration_test(@admin)
      @application = create(:application, :in_progress, :income_not_required, user: @user)
      @application.residency_proof.attach(io: file_fixture('residency_proof.pdf').open, filename: 'residency.pdf', content_type: 'application/pdf')
      @application.id_proof.attach(io: file_fixture('disability_certification_valid.pdf').open, filename: 'id.pdf', content_type: 'application/pdf')
      %w[residency_proof id_proof].each do |slot|
        mark_document_clean!(@application.public_send(slot).blob, user: @user, slot: slot)
      end
      @application.update!(id_proof_status: :approved, disability_certification_status: :approved)
      Applications::ProofDecisionFollowUp.any_instance.stubs(:call).raises(StandardError, 'after commit failed')
    end

    teardown do
      cleanup_duplicate_review_test_data!(@user, @admin)
      Current.reset
    end

    %i[html turbo_stream].each do |format|
      test "#{format} proof review shows a warning for a saved review whose callback failed" do
        submit_review(format)

        assert_redirected_to admin_application_path(@application)
        assert_equal 'Residency proof approved successfully.', flash[:notice]
        assert_match(/review was saved.*follow-up step/, flash[:alert])
        assert_saved_review
        assert @application.events.exists?(action: 'proof_review_follow_up_failed')
      end

      test "#{format} proof review redirects to the application when saved state cannot be confirmed" do
        # The connection is lost as the callback fails, so the reads that follow cannot confirm the commit.
        Applications::ProofDecisionFollowUp.any_instance.stubs(:call).with do
          ProofReview.stubs(:find_by).raises(ActiveRecord::ConnectionNotEstablished, 'verification unavailable')
          true
        end.raises(StandardError, 'after commit failed')

        submit_review(format)

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

    def submit_review(format)
      patch update_proof_status_admin_application_path(@application, format: format),
            params: { proof_type: 'residency', status: 'approved' }
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
