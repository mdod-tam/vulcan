class AddIdProofToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :id_proof_status, :integer, default: 0, null: false
    add_index :applications, :id_proof_status, name: 'idx_applications_on_id_proof_status'
    add_check_constraint :applications, "id_proof_status = ANY (ARRAY[0, 1, 2])", name: "id_proof_status_check"
  end
end
