namespace :db do
  desc "Seed feature flags from db/seeds/feature_flags.rb"
  task seed_feature_flags: :environment do
    load File.expand_path('../../db/seeds/feature_flags.rb', __dir__)
  end
end

namespace :features do
  desc "List all feature flags and their status"
  task list: :environment do
    flags = FeatureFlag.all.order(:name)
    if flags.empty?
      puts "No feature flags found."
    else
      puts "\n📋 Feature Flags Status:"
      puts "─" * 50
      flags.each do |flag|
        status = flag.enabled ? "✅ ENABLED" : "❌ DISABLED"
        puts "  #{flag.name.ljust(30)} #{status}"
      end
      puts "─" * 50
      puts "Total: #{flags.count} flags\n"
    end
  end

  desc "Enable a feature flag (usage: rake features:enable[feature_name])"
  task :enable, [:feature] => :environment do |_t, args|
    feature = args[:feature]
    if feature.blank?
      puts "❌ Error: Feature name required"
      puts "Usage: rake features:enable[feature_name]"
      exit 1
    end

    if FeatureFlag.enable!(feature)
      puts "✅ Enabled feature: #{feature}"
    else
      puts "❌ Failed to enable feature: #{feature}"
    end
  end

  desc "Disable a feature flag (usage: rake features:disable[feature_name])"
  task :disable, [:feature] => :environment do |_t, args|
    feature = args[:feature]
    if feature.blank?
      puts "❌ Error: Feature name required"
      puts "Usage: rake features:disable[feature_name]"
      exit 1
    end

    if FeatureFlag.disable!(feature)
      puts "✅ Disabled feature: #{feature}"
    else
      puts "❌ Failed to disable feature: #{feature}"
    end
  end
end
