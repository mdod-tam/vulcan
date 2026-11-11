# frozen_string_literal: true

class MakeProofReviewsImmutableDecisions < ActiveRecord::Migration[8.1]
  def change
    # The pre-1.0 baseline has no production applications or proof rows. Do not invent historical decision keys.
    # rubocop:disable Rails/NotNullColumn
    add_column :proof_reviews, :decision_key, :string, null: false
    add_column :proof_reviews, :decision_fingerprint, :string, null: false
    # rubocop:enable Rails/NotNullColumn
    # A rejected document is purged; the decision retains its identifier without retaining the blob.
    add_column :proof_reviews, :reviewed_blob_id, :bigint
    add_index :proof_reviews, %i[application_id decision_key], unique: true
    add_index :proof_reviews, %i[application_id proof_type reviewed_at id], name: 'index_proof_reviews_on_decision_history'
  end
end
