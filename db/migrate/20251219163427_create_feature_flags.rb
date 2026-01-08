class CreateFeatureFlags < ActiveRecord::Migration[7.0]
  def change
    create_table :feature_flags do |t|
      t.string :name, null: false
      t.boolean :enabled, null: false, default: false
      t.timestamps
      t.index :name, unique: true
    end
    FeatureFlag.create!(name: 'vouchers_enabled', enabled: false)
  end
end
