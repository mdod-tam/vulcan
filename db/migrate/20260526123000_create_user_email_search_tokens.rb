# frozen_string_literal: true

class CreateUserEmailSearchTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :user_email_search_tokens do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false

      t.timestamps
    end

    add_index :user_email_search_tokens, :token_digest
    add_index :user_email_search_tokens, %i[user_id token_digest], unique: true

    reversible do |dir|
      dir.up do
        User.reset_column_information
        UserEmailSearchToken.reset_column_information

        say_with_time 'Backfilling user email search tokens' do
          User.find_each(&:rebuild_email_search_tokens!)
        end
      end
    end
  end
end
