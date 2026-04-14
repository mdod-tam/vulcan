class AddAlternateContactRelationshipTypeToApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :applications, :alternate_contact_relationship_type, :string
  end
end
