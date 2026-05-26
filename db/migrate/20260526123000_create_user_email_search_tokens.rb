# frozen_string_literal: true

class CreateUserEmailSearchTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :user_email_search_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :token_digest, null: false

      t.timestamps
    end

    add_index :user_email_search_tokens, :token_digest
    add_index :user_email_search_tokens, %i[user_id token_digest], unique: true
  end
end
