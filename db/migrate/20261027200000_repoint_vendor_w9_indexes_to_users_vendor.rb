# frozen_string_literal: true

class RepointVendorW9IndexesToUsersVendor < ActiveRecord::Migration[8.1]
  def change
    # Vendors are stored as 'Users::Vendor'; a predicate on the bare 'Vendor' matches no row, so Postgres
    # could never use these indexes for vendor queries.
    remove_index :users, :w9_rejections_count, name: 'index_users_on_w9_rejections_count', where: "type = 'Vendor'"
    remove_index :users, :w9_status, name: 'index_users_on_w9_status', where: "type = 'Vendor'"
    add_index :users, :w9_rejections_count, name: 'index_users_on_w9_rejections_count', where: "type = 'Users::Vendor'"
    add_index :users, :w9_status, name: 'index_users_on_w9_status', where: "type = 'Users::Vendor'"
  end
end
