# frozen_string_literal: true

class RemoveMedicalCertificationRejectionReasonFromApplications < ActiveRecord::Migration[8.0]
  def change
    remove_column :applications, :medical_certification_rejection_reason, :text if column_exists?(:applications, :medical_certification_rejection_reason)
  end
end
