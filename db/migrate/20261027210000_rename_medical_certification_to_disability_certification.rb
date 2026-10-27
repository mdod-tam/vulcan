# frozen_string_literal: true

class RenameMedicalCertificationToDisabilityCertification < ActiveRecord::Migration[8.1]
  def change
    # The foreign key's generated name embeds the column, so it is dropped and re-added around the rename.
    # rename_column already renames the two default-named indexes.
    remove_foreign_key :applications, :users, column: :medical_certification_verified_by_id

    rename_column :applications, :medical_certification_request_count, :disability_certification_request_count
    rename_column :applications, :medical_certification_requested_at, :disability_certification_requested_at
    rename_column :applications, :medical_certification_status, :disability_certification_status
    rename_column :applications, :medical_certification_verified_at, :disability_certification_verified_at
    rename_column :applications, :medical_certification_verified_by_id, :disability_certification_verified_by_id

    add_foreign_key :applications, :users, column: :disability_certification_verified_by_id
  end
end
