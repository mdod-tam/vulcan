# frozen_string_literal: true

class MakeProofReviewsImmutableDecisions < ActiveRecord::Migration[8.1]
  def change
    add_column :proof_reviews, :decision_key, :string
    add_column :proof_reviews, :decision_fingerprint, :string
    # A rejected document is purged; the decision retains its identifier without retaining the blob.
    add_column :proof_reviews, :reviewed_blob_id, :bigint

    # The legacy marker cannot match a review request's SHA-256 fingerprint.
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE proof_reviews
          SET decision_key = 'legacy-proof-review:' || id::text,
              decision_fingerprint = 'legacy'
          WHERE decision_key IS NULL
        SQL
      end
    end

    change_column_null :proof_reviews, :decision_key, false
    change_column_null :proof_reviews, :decision_fingerprint, false
    add_index :proof_reviews, %i[application_id decision_key], unique: true
    add_index :proof_reviews, %i[application_id proof_type reviewed_at id], name: 'index_proof_reviews_on_decision_history'
  end
end
