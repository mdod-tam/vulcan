# frozen_string_literal: true

# The hourly expiration job marks each form it records, so later runs scan only
# forms that still need an expiration event.
class AddExpirationRecordedAtToSecureForms < ActiveRecord::Migration[8.1]
  TABLES = {
    secure_request_forms: 'index_secure_request_forms_on_open_expiration',
    medical_provider_secure_request_forms: 'index_med_provider_secure_forms_on_open_expiration',
    vendor_secure_request_forms: 'index_vendor_secure_forms_on_open_expiration'
  }.freeze

  def change
    TABLES.each do |table, index_name|
      add_column table, :expiration_recorded_at, :datetime

      remove_index table, :expires_at, name: index_name,
                                       where: 'status = 0 AND submitted_at IS NULL AND revoked_at IS NULL'
      add_index table, :expires_at, name: index_name,
                                    where: 'status = 0 AND submitted_at IS NULL AND revoked_at IS NULL ' \
                                           'AND expiration_recorded_at IS NULL'
    end
  end
end
