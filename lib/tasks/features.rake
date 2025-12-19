namespace :features do
  desc "List all feature flags and their status"
  task list: :environment do
    puts "Available feature flags:"
    FeatureFlag.all.each do |flag|
      puts "#{flag.name}: #{flag.enabled ? 'ENABLED' : 'DISABLED'}"
    end
  end
  desc "Enable a feature flag"
  task :enable, [:feature] => :environment do |_t, args|
    feature = args[:feature]
    if FeatureFlag.enable!(feature)
      puts "✅ Enabled feature: #{feature}"
    else
      puts "❌ Failed to enable feature: #{feature}"
    end
  end
  desc "Disable a feature flag"
  task :disable, [:feature] => :environment do |_t, args|
    feature = args[:feature]
    if FeatureFlag.disable!(feature)
      puts "✅ Disabled feature: #{feature}"
    else
      puts "❌ Failed to disable feature: #{feature}"
    end
  end
end
