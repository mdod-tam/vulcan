class AddEquipmentFulfillmentDatesToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :equipment_bids_sent_at, :datetime
    add_column :applications, :equipment_po_sent_at, :datetime
  end
end
