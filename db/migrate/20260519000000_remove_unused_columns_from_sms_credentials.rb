class RemoveUnusedColumnsFromSmsCredentials < ActiveRecord::Migration[8.1]
  def change
    remove_column :sms_credentials, :code_digest, :text
    remove_column :sms_credentials, :code_expires_at, :datetime
  end
end
