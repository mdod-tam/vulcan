# frozen_string_literal: true

module EvaluationSystemTestSetup
  extend ActiveSupport::Concern

  included do
    setup do
      ensure_system_audit_actor!
      @evaluator = create(:evaluator)
      @product = create(:product, name: 'Retry Device')
      @replacement_product = create(:product, name: 'Replacement Device')
      @evaluation = create(:evaluation, evaluator: @evaluator, status: :scheduled, evaluation_date: 2.days.from_now)
      system_test_sign_in(@evaluator, bypass_mfa_enrollment: true)
    end
  end
end
