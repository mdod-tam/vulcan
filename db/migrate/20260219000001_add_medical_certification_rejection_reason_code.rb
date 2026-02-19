# frozen_string_literal: true

class AddMedicalCertificationRejectionReasonCode < ActiveRecord::Migration[8.0]
  def change
    add_column :applications, :medical_certification_rejection_reason_code, :string
    add_index :applications, :medical_certification_rejection_reason_code
  end
end
