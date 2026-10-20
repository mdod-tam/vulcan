# frozen_string_literal: true

class EstablishTrainingCoverageAndReports < ActiveRecord::Migration[8.1]
  def change
    add_reference :applications, :assigned_trainer, null: true, foreign_key: { to_table: :users }
    rename_column :training_sessions, :notes, :internal_notes
    add_column :training_sessions, :constituent_summary, :text
    add_column :training_sessions, :summary_locale, :string
    add_column :training_sessions, :report_submitted_at, :datetime
    add_index :training_sessions, :application_id, unique: true,
                                                   where: 'status IN (0, 1, 2)', name: 'index_training_sessions_one_open_per_application'
  end
end
