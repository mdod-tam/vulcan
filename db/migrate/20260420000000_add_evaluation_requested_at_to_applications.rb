# frozen_string_literal: true

# Adds `evaluation_requested_at` to applications so evaluation requests
# become explicit, persisted application state mirroring the role of
# `training_requested_at`. This lets admins queue "this person needs an
# evaluation" without inferring it from fulfillment_type or voucher flags.
class AddEvaluationRequestedAtToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :evaluation_requested_at, :datetime
    add_index :applications, :evaluation_requested_at
  end
end
