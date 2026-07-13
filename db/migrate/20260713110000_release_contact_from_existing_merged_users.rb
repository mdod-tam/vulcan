# frozen_string_literal: true

# PR192 released only contact selected for transfer. PR193 makes the canonical user the
# sole live owner of both primary contacts, so bring already-merged rows up to that
# invariant before ordinary model updates begin enforcing it.
class ReleaseContactFromExistingMergedUsers < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE users
         SET email = NULL,
             phone = NULL,
             updated_at = CURRENT_TIMESTAMP
       WHERE merged_into_user_id IS NOT NULL
         AND (email IS NOT NULL OR phone IS NOT NULL)
    SQL
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Released contact facts cannot be reconstructed safely'
  end
end
