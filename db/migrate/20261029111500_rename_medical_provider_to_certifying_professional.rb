# frozen_string_literal: true

class RenameMedicalProviderToCertifyingProfessional < ActiveRecord::Migration[8.1]
  def up
    # Rails names the foreign key fk_rails_<hash of table and column>, so renaming the column would leave the old
    # hash behind. Drop and re-add it so a migrated database matches a fresh schema load.
    # rename_column already renames the default-named index on users.certifying_professional_id.
    remove_foreign_key :users, :users, column: :medical_provider_id

    rename_column :users, :medical_provider_id, :certifying_professional_id
    rename_column :applications, :medical_provider_name, :certifying_professional_name
    rename_column :applications, :medical_provider_phone, :certifying_professional_phone
    rename_column :applications, :medical_provider_email, :certifying_professional_email
    rename_column :applications, :medical_provider_fax, :certifying_professional_fax
    rename_column :applications, :medical_release_authorized, :disability_information_release_authorized

    add_foreign_key :users, :users, column: :certifying_professional_id

    # rename_column also renames index_applications_on_medical_provider_email_and_status, which
    # follows the default index naming convention.
  end

  def down
    rename_column :applications, :disability_information_release_authorized, :medical_release_authorized
    rename_column :applications, :certifying_professional_fax, :medical_provider_fax
    rename_column :applications, :certifying_professional_email, :medical_provider_email
    rename_column :applications, :certifying_professional_phone, :medical_provider_phone
    rename_column :applications, :certifying_professional_name, :medical_provider_name

    remove_foreign_key :users, :users, column: :certifying_professional_id
    rename_column :users, :certifying_professional_id, :medical_provider_id
    add_foreign_key :users, :users, column: :medical_provider_id
  end
end
