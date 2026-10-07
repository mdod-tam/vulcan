# frozen_string_literal: true

# The tracking number staff record for an equipment-fulfillment order, beside the bids-sent and PO-sent dates.
class AddEquipmentTrackingNumberToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :equipment_tracking_number, :string
  end
end
