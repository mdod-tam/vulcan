# frozen_string_literal: true

class RemoveLegacyEquipmentFulfillmentFromApplications < ActiveRecord::Migration[8.1]
  def change
    remove_column :applications, :equipment_bids_sent_at, :datetime
    remove_column :applications, :equipment_po_sent_at, :datetime
    remove_column :applications, :equipment_tracking_number, :string
  end
end
