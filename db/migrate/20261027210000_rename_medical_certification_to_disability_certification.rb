# frozen_string_literal: true

class RenameMedicalCertificationToDisabilityCertification < ActiveRecord::Migration[8.1]
  def change
    # Rails names the foreign key fk_rails_<hash of table and column>, so renaming the column would leave the old
    # hash behind. Drop and re-add it so a migrated database matches a fresh schema load.
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
