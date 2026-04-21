# frozen_string_literal: true

def seed_feature_flags
  seed_puts 'Seeding feature flags...'

  feature_flags = {
    'vouchers_enabled' => false,
    'income_proof_required' => true
  }

  feature_flags.each do |name, enabled|
    FeatureFlag.find_or_create_by!(name: name) do |flag|
      flag.enabled = enabled
    end
    seed_success "  ✓ Created feature flag: #{name} (enabled: #{enabled})"
  end
end

seed_feature_flags
