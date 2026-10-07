# frozen_string_literal: true

class AddChangeValuesToEvents < ActiveRecord::Migration[8.1]
  def change
    # Old and new values of fields the audited record encrypts, stored encrypted (see Event).
    add_column :events, :change_values, :text
  end
end
