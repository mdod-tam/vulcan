# frozen_string_literal: true

class AddSecureFormExpirationIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :secure_request_forms,
              :expires_at,
              name: 'index_secure_request_forms_on_open_expiration',
              where: 'status = 0 AND submitted_at IS NULL AND revoked_at IS NULL'

    add_index :medical_provider_secure_request_forms,
              :expires_at,
              name: 'index_med_provider_secure_forms_on_open_expiration',
              where: 'status = 0 AND submitted_at IS NULL AND revoked_at IS NULL'

    add_index :vendor_secure_request_forms,
              :expires_at,
              name: 'index_vendor_secure_forms_on_open_expiration',
              where: 'status = 0 AND submitted_at IS NULL AND revoked_at IS NULL'
  end
end
