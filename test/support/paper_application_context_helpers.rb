# frozen_string_literal: true

# Paper Application Context Helpers
#
# This module provides context setup for paper application tests.
# It's designed to work with the centralized ApplicationSystemTestCase.
module PaperApplicationContextHelpers
  def setup_paper_application_context
    # Set paper application context flags
    Thread.current[:paper_application_context] = true
    Current.paper_context = true
    Current.skip_proof_validation = true

    # Also set the application skip flag that's used in ApplicationSystemTestCase
    Application.skip_wait_period_validation = true
  end

  def teardown_paper_application_context
    # Clear paper application context
    Thread.current[:paper_application_context] = nil
    Current.reset
  end

  # Simple helper to check if we're in paper context
  def paper_application_context?
    Thread.current[:paper_application_context] || Current.paper_context
  end
end
