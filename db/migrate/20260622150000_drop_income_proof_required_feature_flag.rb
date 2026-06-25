# frozen_string_literal: true

# Removes the obsolete `income_proof_required` feature flag. Income proof
# requirement is now derived from the single `vouchers_enabled` flag (income is
# required only when vouchers are disabled), so the standalone flag is no longer
# read anywhere in the application.
class DropIncomeProofRequiredFeatureFlag < ActiveRecord::Migration[8.0]
  def up
    FeatureFlag.where(name: 'income_proof_required').delete_all
  end

  def down
    FeatureFlag.find_or_create_by!(name: 'income_proof_required') do |f|
      f.enabled = true
    end
  end
end
