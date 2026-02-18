# frozen_string_literal: true

class AddRejectionReasonCodeToProofReviews < ActiveRecord::Migration[8.0]
  def change
    add_column :proof_reviews, :rejection_reason_code, :string
    add_index  :proof_reviews, :rejection_reason_code
  end
end
