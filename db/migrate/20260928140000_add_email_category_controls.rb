# frozen_string_literal: true

# One control per email category, enabled, plus a cancellation generation on email templates so
# turning a template pair off cancels mail captured under the old generation. Existing rows keep
# their ids, enabled values, and generations; reruns never re-enable anything.
class AddEmailCategoryControls < ActiveRecord::Migration[8.1]
  CATEGORIES = %w[
    proof registration voucher vendor certification training evaluation account_security application
  ].freeze

  def up
    add_column :email_templates, :delivery_generation, :bigint, default: 0, null: false

    values = CATEGORIES.map { |category| "('email.category.#{category}', TRUE, 0, NOW(), NOW())" }.join(', ')
    execute <<~SQL.squish
      INSERT INTO feature_flags (name, enabled, delivery_generation, created_at, updated_at)
      VALUES #{values}
      ON CONFLICT (name) DO NOTHING
    SQL
  end

  def down
    execute "DELETE FROM feature_flags WHERE name LIKE 'email.category.%'"
    remove_column :email_templates, :delivery_generation
  end
end
