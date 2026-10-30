# frozen_string_literal: true

require 'test_helper'

class ProofConsistencyCheckJobTest < ActiveJob::TestCase
  test 'reports an approved proof that has no file' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(income_proof_status: Application.income_proof_statuses[:approved])

    warnings = warnings_from { ProofConsistencyCheckJob.perform_now }

    assert_includes warnings, "Inconsistent proof state for application #{application.id}: income_proof is approved but has no attached file"
  end

  test 'reports only the proof that lacks a file when the application has another proof attached' do
    application = create(:application, :in_progress, :with_income_proof, skip_proofs: true)
    application.update_columns(income_proof_status: Application.income_proof_statuses[:approved],
                               residency_proof_status: Application.residency_proof_statuses[:approved])

    warnings = warnings_from { ProofConsistencyCheckJob.perform_now }

    assert_includes warnings, "Inconsistent proof state for application #{application.id}: residency_proof is approved but has no attached file"
    assert_empty application_warnings(warnings, application, 'income_proof')
  end

  test 'does not report an approved proof that has its file' do
    application = create(:application, :in_progress, :with_income_proof, :with_residency_proof, skip_proofs: true)
    application.update_columns(income_proof_status: Application.income_proof_statuses[:approved],
                               residency_proof_status: Application.residency_proof_statuses[:approved])

    warnings = warnings_from { ProofConsistencyCheckJob.perform_now }

    assert_empty application_warnings(warnings, application)
  end

  test 'does not report a proof that is attached and awaiting review' do
    application = create(:application, :in_progress, :with_income_proof, :with_residency_proof, skip_proofs: true)
    assert_predicate application, :income_proof_status_not_reviewed?
    assert_predicate application, :residency_proof_status_not_reviewed?

    warnings = warnings_from { ProofConsistencyCheckJob.perform_now }

    assert_empty application_warnings(warnings, application)
  end

  test 'does not report a proof that is waiting for its file' do
    waiting = create(:application, :in_progress, skip_proofs: true)
    rejected = create(:application, :in_progress, skip_proofs: true)
    rejected.update_columns(income_proof_status: Application.income_proof_statuses[:rejected],
                            residency_proof_status: Application.residency_proof_statuses[:rejected])

    warnings = warnings_from { ProofConsistencyCheckJob.perform_now }

    assert_empty application_warnings(warnings, waiting)
    assert_empty application_warnings(warnings, rejected)
  end

  test 'only logs: it changes no proof and notifies no one' do
    application = create(:application, :in_progress, skip_proofs: true)
    application.update_columns(income_proof_status: Application.income_proof_statuses[:approved])

    assert_no_difference ['Notification.count', 'Event.count', 'ActiveStorage::Attachment.count'] do
      assert_no_enqueued_jobs do
        ProofConsistencyCheckJob.perform_now
      end
    end

    assert_predicate application.reload, :income_proof_status_approved?
  end

  private

  # The block form of `with` matches every call; appending returns the array, which is truthy.
  def warnings_from
    messages = []
    Rails.logger.stubs(:warn).with { |message| messages << message }
    yield
    messages
  end

  def application_warnings(warnings, application, attachment_name = nil)
    prefix = "Inconsistent proof state for application #{application.id}: #{attachment_name}"
    warnings.select { |message| message.start_with?(prefix) }
  end
end
