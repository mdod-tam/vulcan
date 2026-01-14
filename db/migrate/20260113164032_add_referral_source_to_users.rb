class AddReferralSourceToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :referral_source, :string
  end
end
