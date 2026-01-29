# frozen_string_literal: true

# Helper module for managing proofs in tests
module ProofTestHelper
  def clear_current_context
    Current.user = nil
    Current.proof_attachment_service_context = nil
    Current.paper_context = nil
    Current.resubmitting_proof = nil
    Current.skip_proof_validation = nil
    Current.reviewing_single_proof = nil
  end

  # Set up a clean test environment with proper context clearing
  def setup_clean_test_environment
    clear_current_context
    Event.delete_all if defined?(Event)
    ensure_active_storage_test_setup
  end

  private

  def ensure_active_storage_test_setup
    storage_dir = Rails.root.join('tmp/storage')
    FileUtils.mkdir_p(storage_dir) unless storage_dir.exist?
  end

  public

  # Create an application ready for proof submission testing
  def create_application_for_proof_submission(user: nil)
    clear_current_context

    attributes = {}
    attributes[:user] = user if user

    app = create(:application, **attributes)
    app.update_columns(
      income_proof_status: Application.income_proof_statuses[:rejected],
      residency_proof_status: Application.residency_proof_statuses[:rejected],
      status: Application.statuses[:awaiting_proof],
      needs_review_since: nil
    )

    app.reload
  end

  # Create an application ready for admin review
  def create_application_for_review(user: nil)
    clear_current_context

    attributes = {
      income_proof_status: :not_reviewed,
      residency_proof_status: :not_reviewed,
      needs_review_since: Time.current
    }
    attributes[:user] = user if user

    create(:application, :with_all_proofs, **attributes)
  end

  # Assert that the correct number of events were created
  def assert_event_count(expected_count, event_action: nil)
    if event_action
      actual_count = Event.where(action: event_action).count
      assert_equal expected_count, actual_count,
                   "Expected #{expected_count} #{event_action} events, got #{actual_count}"
    else
      actual_count = Event.count
      assert_equal expected_count, actual_count,
                   "Expected #{expected_count} total events, got #{actual_count}"
    end
  end

  # Assert that no duplicate events were created
  def assert_no_duplicate_events
    duplicate_groups = Event.group(:action, :auditable_type, :auditable_id, :user_id)
                            .having('COUNT(*) > 1')
                            .count

    assert_empty duplicate_groups,
                 "Found duplicate events: #{duplicate_groups.inspect}"
  end

  # Legacy method for compatibility - sets up basic attachment mocks
  def setup_attachment_mocks_for_audit_logs
    # This is a no-op method for compatibility with existing tests. Tests should use factory traits instead
  end

  # Legacy method for compatibility - prepares application for testing
  def prepare_application_for_test(app, options = {})
    options = {
      status: 'in_progress',
      income_proof_status: 'not_reviewed',
      residency_proof_status: 'not_reviewed'
    }.merge(options)

    app.update!(
      status: options[:status],
      income_proof_status: options[:income_proof_status],
      residency_proof_status: options[:residency_proof_status]
    )

    app
  end
end
