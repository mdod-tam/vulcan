# frozen_string_literal: true

# Context setup for paper application tests.
module PaperApplicationContextHelpers
  def setup_paper_application_context
    Thread.current[:paper_application_context] = true
    Current.paper_context = true
    Current.skip_proof_validation = true

    # Skip the waiting-period validation.
    Application.skip_wait_period_validation = true

    # Ensure the single workflow feature flag exists with its default so that
    # stamp_workflow_defaults! and scrub_income_fields behave correctly.
    FeatureFlag.find_or_create_by!(name: 'vouchers_enabled') { |f| f.enabled = false }
  end

  def teardown_paper_application_context
    Thread.current[:paper_application_context] = nil
    Current.reset if defined?(Current) && Current.respond_to?(:reset)
  end

  def paper_application_context?
    Thread.current[:paper_application_context] || Current.paper_context
  end
end
