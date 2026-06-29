# frozen_string_literal: true

# rubocop:disable Rails/Output

def seed_feature_flags
  puts 'Seeding feature flags...'

  # `vouchers_enabled` is the single switch for the voucher fulfillment workflow.
  # Income proof requirement is derived from it: income is NOT required when
  # vouchers are enabled, and required when they are disabled.
  feature_flags = {
    'vouchers_enabled' => false
  }

  feature_flags.each do |name, enabled|
    FeatureFlag.find_or_create_by!(name: name) do |flag|
      flag.enabled = enabled
    end
    puts "  ✓ Created feature flag: #{name} (enabled: #{enabled})"
  end
end

seed_feature_flags

# rubocop:enable Rails/Output
