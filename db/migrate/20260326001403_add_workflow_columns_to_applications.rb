# frozen_string_literal: true

class AddWorkflowColumnsToApplications < ActiveRecord::Migration[8.0]
  def change
    add_column :applications, :fulfillment_type, :integer, default: 0, null: false
    add_column :applications, :income_proof_required, :boolean, default: true, null: false

    change_column_default :applications, :fulfillment_type, from: 0, to: nil
    change_column_default :applications, :income_proof_required, from: true, to: nil

    add_index :applications, :fulfillment_type

    reversible do |dir|
      dir.up do
        FeatureFlag.find_or_create_by!(name: 'income_proof_required') do |f|
          f.enabled = true
        end
      end
    end
  end
end
