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

    test 'approve income proof responds with turbo streams: update modals container and replace attachments' do
      attach_income_proof!

      approved_review = build(
        :proof_review,
        application: @application,
        admin: @admin,
        proof_type: 'income',
        status: 'approved'
      )

      Applications::ProofReviewer.any_instance.stubs(:review).returns(approved_review)

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'approved' },
            as: :turbo_stream

      assert_response :success
      # Must be a turbo stream response
      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      # Validate stream actions - modals container is replaced (closes all modals and regenerates them)
      assert_turbo_stream action: 'update', target: 'modals'
      assert_turbo_stream action: 'update', target: 'attachments-section'
    end

    test 'reject income proof responds with turbo streams: update modals container and replace attachments' do
      attach_income_proof!

      rejected_review = build(
        :proof_review,
        application: @application,
        admin: @admin,
        proof_type: 'income',
        status: 'rejected',
        rejection_reason: 'invalid_document',
        notes: 'Please upload a valid PDF.'
      )

      Applications::ProofReviewer.any_instance.stubs(:review).returns(rejected_review)

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'income', status: 'rejected', rejection_reason: 'invalid_document', notes: 'Please upload a valid PDF.' },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      # The controller replaces the modals container (closes all modals and regenerates them)
      assert_turbo_stream action: 'update', target: 'modals'
      assert_turbo_stream action: 'update', target: 'attachments-section'
    end

    test 'approve residency proof responds with turbo streams: update modals container and replace attachments' do
      # Attach residency proof and keep income untouched
      @application.residency_proof.attach(io: StringIO.new('test content'), filename: 'residency.pdf', content_type: 'application/pdf')

      approved_review = build(
        :proof_review,
        application: @application,
        admin: @admin,
        proof_type: 'residency',
        status: 'approved'
      )

      Applications::ProofReviewer.any_instance.stubs(:review).returns(approved_review)

      patch update_proof_status_admin_application_path(@application),
            params: { proof_type: 'residency', status: 'approved' },
            as: :turbo_stream

      assert_response :success
      assert_equal 'text/vnd.turbo-stream.html', response.media_type

      # Modals container is replaced (closes all modals and regenerates them)
      assert_turbo_stream action: 'update', target: 'modals'
      assert_turbo_stream action: 'update', target: 'attachments-section'
    end
  end
end
