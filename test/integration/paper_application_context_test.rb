# frozen_string_literal: true

require 'test_helper'

class PaperApplicationContextTest < ActionDispatch::IntegrationTest
  setup do
    @constituent = FactoryBot.create(:constituent)
    @application = FactoryBot.create(:application,
                                     user: @constituent,
                                     status: :in_progress,
                                     submission_method: :online)
  end

  test 'approving proofs without attachments is refused for an online submission' do
    approve_both_proofs(@application)

    assert_not @application.save, 'Application should fail validation without attached proofs when status is approved'

    assert_includes @application.errors[:income_proof], 'must be attached when status is approved'
    assert_includes @application.errors[:residency_proof], 'must be attached when status is approved'
  end

  test 'approving proofs without attachments is allowed for a paper submission' do
    paper_application = FactoryBot.create(:application,
                                          user: FactoryBot.create(:constituent),
                                          status: :in_progress,
                                          submission_method: :paper)
    approve_both_proofs(paper_application)

    assert paper_application.save,
           "A paper submission keeps its proofs on paper. Errors: #{paper_application.errors.full_messages.join(', ')}"
  end

  test 'paper context does not change whether proofs must be attached' do
    approve_both_proofs(@application)

    saved = Current.set(paper_context: true) { @application.save }

    assert_not saved, 'Paper context is intake state, not a validation bypass'
    assert_includes @application.errors[:income_proof], 'must be attached when status is approved'
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
    assert_nil Current.paper_context, 'Current should be reset after exception and cleanup'
  end

  private

  def approve_both_proofs(application)
    application.income_proof_status = :approved
    application.residency_proof_status = :approved
  end
end
