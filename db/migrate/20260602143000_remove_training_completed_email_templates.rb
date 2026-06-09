# frozen_string_literal: true

class RemoveTrainingCompletedEmailTemplates < ActiveRecord::Migration[8.1]
  TEMPLATE_NAME = 'training_session_notifications_training_completed'

  def up
    EmailTemplate.where(name: TEMPLATE_NAME).delete_all
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
