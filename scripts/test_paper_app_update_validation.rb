#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script to reproduce paper application update validation issue
#
# Usage:
#   rails runner scripts/test_paper_app_update_validation.rb APPLICATION_ID

application_id = ARGV[0]

if application_id.blank?
  puts 'Error: Please provide an application ID'
  puts 'Usage: rails runner scripts/test_paper_app_update_validation.rb APPLICATION_ID'
  exit 1
end

app = Application.find_by(id: application_id)

unless app
  puts "Error: Application with ID #{application_id} not found"
  exit 1
end

puts "\n" + ('=' * 80)
puts 'Paper Application Update Validation Test'
puts '=' * 80
puts "\nApplication ID: #{app.id}"
puts "Status: #{app.status}"
puts "Submission Method: #{app.submission_method}"
puts "\n" + ('-' * 80)

# Current state
puts "\nCURRENT STATE:"
puts "Income Proof: #{app.income_proof_status} (attached: #{app.income_proof.attached?})"
puts "Residency Proof: #{app.residency_proof_status} (attached: #{app.residency_proof.attached?})"

# Test 1: Direct update without context
puts "\n" + ('=' * 80)
puts 'TEST 1: Update WITHOUT Current.paper_context'
puts '=' * 80
puts "\nAttempting: app.update(household_size: #{app.household_size || 1})"

app.valid?
if app.errors.any?
  puts '✗ Validation FAILED (before update)'
  puts "\nErrors:"
  app.errors.full_messages.each { |msg| puts "  - #{msg}" }

  puts "\nValidation details:"
  app.errors.details.each do |field, details|
    puts "  #{field}:"
    details.each do |detail|
      puts "    - #{detail[:error]}: #{detail.inspect}"
    end
  end
else
  puts '✓ Validation PASSED (before update)'

  # Try actual update
  begin
    result = app.update(household_size: app.household_size || 1)
    if result
      puts '✓ Update SUCCEEDED'
    else
      puts '✗ Update FAILED'
      puts "\nErrors:"
      app.errors.full_messages.each { |msg| puts "  - #{msg}" }
    end
  rescue StandardError => e
    puts "✗ Exception during update: #{e.message}"
  end
end

# Reload
app.reload

# Test 2: Update WITH paper context
puts "\n" + ('=' * 80)
puts 'TEST 2: Update WITH Current.paper_context = true'
puts '=' * 80
puts "\nAttempting: app.update(household_size: #{app.household_size || 1})"

begin
  Current.paper_context = true

  app.valid?
  if app.errors.any?
    puts '✗ Validation FAILED (before update)'
    puts "\nErrors:"
    app.errors.full_messages.each { |msg| puts "  - #{msg}" }
  else
    puts '✓ Validation PASSED (before update)'

    result = app.update(household_size: app.household_size || 1)
    if result
      puts '✓ Update SUCCEEDED'
    else
      puts '✗ Update FAILED'
      puts "\nErrors:"
      app.errors.full_messages.each { |msg| puts "  - #{msg}" }
    end
  end
ensure
  Current.paper_context = nil
end

# Reload
app.reload

# Test 3: Check which validation is failing
puts "\n" + ('=' * 80)
puts 'TEST 3: Validation Deep Dive'
puts '=' * 80

# Check skip_proof_validation?
puts "\nProofConsistencyValidation checks:"
if app.respond_to?(:skip_proof_validation?, true)
  begin
    skip_result = app.send(:skip_proof_validation?)
    puts "  skip_proof_validation?: #{skip_result}"

    if skip_result
      puts '  ✓ ProofConsistencyValidation will be SKIPPED'
    else
      puts '  ✗ ProofConsistencyValidation will RUN'

      # Manually check what would fail
      puts "\n  Manual check:"
      puts "    submission_method: #{app.submission_method.inspect}"
      puts "    submission_method == :paper: #{app.submission_method&.to_sym == :paper}"

      if app.submission_method&.to_sym == :paper
        puts '    ✓ Will skip via line 39 (submission_method check)'
      else
        puts '    ✗ Will NOT skip via line 39'

        # Check consistency
        puts "\n    Income proof check:"
        puts "      status: #{app.income_proof_status}"
        puts "      attached: #{app.income_proof.attached?}"
        puts "      Would fail?: #{app.income_proof_status == 'approved' && !app.income_proof.attached?}"

        puts "\n    Residency proof check:"
        puts "      status: #{app.residency_proof_status}"
        puts "      attached: #{app.residency_proof.attached?}"
        puts "      Would fail?: #{app.residency_proof_status == 'approved' && !app.residency_proof.attached?}"
      end
    end
  rescue StandardError => e
    puts "  Error: #{e.message}"
  end
end

# Check ProofManageable validations
puts "\nProofManageable checks:"
if app.respond_to?(:require_proof_validations?, true)
  begin
    require_result = app.send(:require_proof_validations?)
    puts "  require_proof_validations?: #{require_result}"

    if require_result
      puts '  ✗ ProofManageable validation will RUN'
      puts "\n  This will require BOTH proofs to be attached!"
      puts "    Income attached: #{app.income_proof.attached?}"
      puts "    Residency attached: #{app.residency_proof.attached?}"
    else
      puts '  ✓ ProofManageable validation will be SKIPPED'
    end

    # Check skip contexts
    if app.respond_to?(:skip_validation_contexts?, true)
      skip_contexts = app.send(:skip_validation_contexts?)
      puts "\n  skip_validation_contexts?: #{skip_contexts}"
      puts "    Current.paper_context: #{Current.paper_context?.inspect}"
      puts "    Current.skip_proof_validation: #{Current.skip_proof_validation?.inspect}"
      puts "    Rails.env.test?: #{Rails.env.test?}"
    end
  rescue StandardError => e
    puts "  Error: #{e.message}"
  end
end

# Test 4: Test via PaperApplicationService
puts "\n" + ('=' * 80)
puts 'TEST 4: Update via PaperApplicationService (Recommended)'
puts '=' * 80

puts "\nThis is how updates SHOULD be performed for paper applications."
puts 'The service automatically sets Current.paper_context = true'
puts "\nExample usage:"
puts <<~CODE
  service = Applications::PaperApplicationService.new(
    params: {
      application: { household_size: #{app.household_size || 1} },
      income_proof_action: 'reject',
      residency_proof_action: 'reject'
    },
    admin: current_admin
  )
  service.update(app)
CODE

puts "\n" + ('=' * 80)
puts 'SUMMARY & RECOMMENDATIONS'
puts '=' * 80

if app.submission_method != 'paper'
  puts "\n⚠ WARNING: submission_method is '#{app.submission_method}', not 'paper'"
  puts '   This application may not have been created via PaperApplicationService'
  puts "\n   FIX: app.update_column(:submission_method, 'paper')"
end

if app.income_proof_status == 'not_reviewed' && !app.income_proof.attached?
  puts "\n⚠ WARNING: Income proof is 'not_reviewed' without attachment"
  puts '   This state will cause validation failures'
  puts "\n   FIX: Reject the proof or upload attachment"
end

if app.residency_proof_status == 'not_reviewed' && !app.residency_proof.attached?
  puts "\n⚠ WARNING: Residency proof is 'not_reviewed' without attachment"
  puts '   This state will cause validation failures'
  puts "\n   FIX: Reject the proof or upload attachment"
end

if app.income_proof_status == 'approved' && !app.income_proof.attached?
  puts "\n⚠ CRITICAL: Income proof is 'approved' without attachment"
  puts '   This violates ProofConsistencyValidation (line 49)'
  puts "\n   FIX: Either attach proof or change status to 'rejected'"
end

if app.residency_proof_status == 'approved' && !app.residency_proof.attached?
  puts "\n⚠ CRITICAL: Residency proof is 'approved' without attachment"
  puts '   This violates ProofConsistencyValidation (line 49)'
  puts "\n   FIX: Either attach proof or change status to 'rejected'"
end

puts "\n" + ('=' * 80)
puts 'Complete'
puts '=' * 80
puts ''
