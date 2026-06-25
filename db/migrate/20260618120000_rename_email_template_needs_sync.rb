# frozen_string_literal: true

class RenameEmailTemplateNeedsSync < ActiveRecord::Migration[8.1]
  def change
    rename_column :email_templates, :needs_sync, :locale_needs_sync
  end
end
