# frozen_string_literal: true

class AddIdentityVerificationToRecoveryRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :recovery_requests, :verification_method, :string
    add_column :recovery_requests, :verification_result, :string
    add_column :recovery_requests, :verification_reference, :string, limit: 200
  end
end
