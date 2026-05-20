class AddUniqueIndexToSmsCredentialsOnUserAndPhone < ActiveRecord::Migration[8.1]
  INDEX_NAME = 'index_sms_credentials_on_user_id_and_phone_number'.freeze

  def up
    execute <<~SQL.squish
      DELETE FROM sms_credentials
      WHERE id IN (
        SELECT id
        FROM (
          SELECT id,
                 ROW_NUMBER() OVER (PARTITION BY user_id, phone_number ORDER BY id ASC) AS duplicate_rank
          FROM sms_credentials
        ) duplicate_sms_credentials
        WHERE duplicate_rank > 1
      )
    SQL

    add_index :sms_credentials, %i[user_id phone_number], unique: true, name: INDEX_NAME, if_not_exists: true
  end

  def down
    remove_index :sms_credentials, name: INDEX_NAME, if_exists: true
  end
end
