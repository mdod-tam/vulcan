# frozen_string_literal: true

require 'test_helper'

class PaperApplicationContextTest < ActionDispatch::IntegrationTest
  setup do
    @constituent = FactoryBot.create(:constituent)
    @application = FactoryBot.create(:application,
                                     user: @constituent,
                                     status: :in_progress,
                                     submission_method: :online, # Online submissions run the proof validations
                                     income_proof_status: :approved, # Status requires attachment
                                     residency_proof_status: :approved) # Status requires attachment
    @application.income_proof.detach
    @application.residency_proof.detach
  end

  test 'proof validations are enforced without paper application context' do
    assert_not @application.save, 'Application should fail validation without attached proofs when status is approved'

    assert_includes @application.errors[:income_proof], 'must be attached when status is approved'
    assert_includes @application.errors[:residency_proof], 'must be attached when status is approved'

    proof_errors = @application.errors.to_hash.keys.select { |k| k.to_s.include?('proof') }
    assert_not_empty proof_errors, 'Expected proof-related validation errors'
  end

  test 'proof validations are skipped within paper application context' do
    saved_successfully = false
    begin
      setup_paper_application_context
      saved_successfully = @application.save
    ensure
      teardown_paper_application_context
    end

    assert saved_successfully,
           "Application should save successfully within paper context, bypassing proof attachment validation. Errors: #{@application.errors.full_messages.join(', ')}"
    assert_empty @application.errors, 'Application should have no validation errors when saved in paper context'
  end

  test 'paper application context is properly cleaned up after exception' do
    assert_nil Thread.current[:paper_application_context], 'Context should be nil initially'

    begin
      setup_paper_application_context
      raise StandardError, 'Simulated error during processing'
    rescue StandardError
      # The error is expected; the ensure block clears the context.
    ensure
      teardown_paper_application_context
    end

    assert_nil Thread.current[:paper_application_context], 'Context should be nil after exception and cleanup'

    # A fresh constituent and application avoid the three-year waiting period validation.
    fresh_constituent = FactoryBot.create(:constituent)
    fresh_application = FactoryBot.create(:application,
                                          user: fresh_constituent,
                                          status: :in_progress,
                                          income_proof_status: :approved) # Invalid state - approved but no proof attached

    fresh_application.income_proof.detach if fresh_application.income_proof.attached?
    fresh_application.residency_proof.detach if fresh_application.residency_proof.attached?

    fresh_application.errors.clear

    assert_not fresh_application.valid?, 'Validation should be active again after context cleanup'
  end
end
