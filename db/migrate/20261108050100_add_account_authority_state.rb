class AddAccountAuthorityState < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :security_version, :bigint, default: 0, null: false
    add_check_constraint :users, 'security_version >= 0', name: 'users_security_version_nonnegative'
    add_column :sessions, :reauthenticated_at, :datetime
    add_column :sessions, :reauthenticated_security_version, :bigint
  end
end
