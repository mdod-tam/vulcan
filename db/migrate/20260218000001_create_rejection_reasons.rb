# frozen_string_literal: true

class CreateRejectionReasons < ActiveRecord::Migration[8.0]
  def change
    create_table :rejection_reasons do |t|
      t.string  :code,          null: false
      t.string  :proof_type,    null: false
      t.string  :locale,        null: false, default: 'en'
      t.text    :body,          null: false
      t.boolean :needs_sync,    null: false, default: false
      t.integer :version,       null: false, default: 1
      t.text    :previous_body
      t.bigint  :updated_by_id

      t.timestamps
    end

    add_index :rejection_reasons, %i[code proof_type locale], unique: true,
              name: 'index_rejection_reasons_on_code_proof_type_locale'
    add_index :rejection_reasons, :updated_by_id
  end
end
