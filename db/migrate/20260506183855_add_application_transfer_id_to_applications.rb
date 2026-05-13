class AddApplicationTransferIdToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :application_transfer_id, :string, if_not_exists: true
  end
end
