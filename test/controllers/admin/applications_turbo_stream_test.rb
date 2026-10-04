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
      @application.income_proof.attach(io: StringIO.new('test content'), filename: 'income.pdf', content_type: 'application/pdf')
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

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'rejected', rejection_reason: 'invalid_document', notes: 'Please upload a valid PDF.' },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      # The controller replaces the modals container (closes all modals and regenerates them)
      assert_turbo_stream action: 'update', target: 'modals'
      assert_turbo_stream action: 'update', target: 'attachments-section'
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
      @application.residency_proof.attach(io: StringIO.new('test content'), filename: 'residency.pdf', content_type: 'application/pdf')

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
end
