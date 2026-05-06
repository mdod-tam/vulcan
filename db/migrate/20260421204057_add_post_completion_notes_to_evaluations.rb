class AddPostCompletionNotesToEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :evaluations, :post_completion_notes, :text
  end
end
