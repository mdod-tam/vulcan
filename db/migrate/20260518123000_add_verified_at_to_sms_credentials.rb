class AddVerifiedAtToSmsCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :sms_credentials, :verified_at, :datetime
    add_index :sms_credentials, :verified_at
  end
end
