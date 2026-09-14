# frozen_string_literal: true

# Preserve whose contact/address each delivery uses, independently of the logical recipient.
# delivery_source records bounded constituent, dependent-contact, or guardian provenance.
class AddDeliveryOwnershipToSecureRequestForms < ActiveRecord::Migration[8.0]
  def change
    add_column :secure_request_forms, :delivery_owner_id, :bigint
    add_column :secure_request_forms, :delivery_source, :string
    add_index :secure_request_forms, :delivery_owner_id
    add_foreign_key :secure_request_forms, :users, column: :delivery_owner_id
  end
end
