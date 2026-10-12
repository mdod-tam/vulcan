# frozen_string_literal: true

class AddRecommendationOutcomeAndWorkingNotesToEvaluations < ActiveRecord::Migration[8.1]
  def change
    add_column :evaluations, :recommendation_outcome, :string, default: 'catalog_products', null: false
    add_column :evaluations, :recommendation_notes, :text
    add_column :evaluations, :working_notes, :text
  end
end
