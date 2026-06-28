# frozen_string_literal: true

namespace :db do
  desc 'Seed policies for production (does not require FactoryBot)'
  task seed_policies: :environment do
    puts '📋 Creating policies...'

    # IMPORTANT: All policy keys used in the application MUST be defined here
    # If a policy is missing from this list, Policy.get('key') will return nil
    # This causes unexpected behavior in mailboxes, controllers, and other logic
    policies = {
      'fpl_modifier_percentage' => 400,
      'fpl_1_person' => 15_650,
      'fpl_2_person' => 21_150,
      'fpl_3_person' => 26_650,
      'fpl_4_person' => 32_150,
      'fpl_5_person' => 37_650,
      'fpl_6_person' => 43_150,
      'fpl_7_person' => 48_650,
      'fpl_8_person' => 54_150,
      'max_training_sessions' => 3,
      'waiting_period_years' => 3,
      'proof_submission_rate_limit_web' => 10,
      'proof_submission_rate_limit_email' => 5,
      'proof_submission_rate_period' => 24,
      'max_proof_rejections' => 3,
      'secure_form_link_expiration_hours' => 48,
      'secure_form_resend_cooldown_hours' => 1,
      # Voucher policies
      'voucher_value_hearing_disability' => 500,
      'voucher_value_vision_disability' => 500,
      'voucher_value_speech_disability' => 500,
      'voucher_value_mobility_disability' => 500,
      'voucher_value_cognition_disability' => 500,
      'voucher_validity_period_months' => 6,
      'voucher_minimum_redemption_amount' => 10
    }

    created_count = 0
    updated_count = 0

    policies.each do |key, value|
      policy = Policy.find_or_initialize_by(key: key)

      if policy.new_record?
        policy.value = value
        policy.save!
        created_count += 1
        puts "  ✓ Created policy: #{key} = #{value}"
      elsif policy.value != value
        old_value = policy.value
        policy.value = value
        policy.updated_by = User.system_user
        policy.save!
        updated_count += 1
        puts "  ✓ Updated policy: #{key} (#{old_value} → #{value})"
      else
        puts "  - Policy already exists: #{key} = #{value}"
      end
    end

    puts "\n📊 Summary:"
    puts "  Total policies: #{Policy.count}"
    puts "  Created: #{created_count}"
    puts "  Updated: #{updated_count}"
    puts '✅ Policy seeding completed successfully!'
  rescue StandardError => e
    puts "❌ Error seeding policies: #{e.message}"
    puts e.backtrace.first(5)
    raise
  end
end
