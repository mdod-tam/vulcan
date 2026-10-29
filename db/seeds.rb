# frozen_string_literal: true

# Production initializes through bin/rails db:bootstrap. This file's demo data needs FactoryBot and deletes existing records.
if Rails.env.production?
  load Rails.root.join('db/seeds/production.rb')
  return
end

# Prevent payment notification callback during seeding
begin
  Invoice.skip_callback(:save, :after, :send_payment_notification)
rescue StandardError => e
  Rails.logger.debug { "[SEED ERROR] Failed to skip Invoice callback: #{e.message}" }
end

require 'yaml'
require 'active_record/fixtures'

def seed_puts(message)
  Rails.logger.debug message if ENV['VERBOSE_TESTS'] || Rails.env.development?
end

def seed_error(message)
  Rails.logger.debug { "[SEED ERROR] #{message}" }
end

def seed_success(message)
  Rails.logger.debug message if ENV['VERBOSE_TESTS']
end

def attach_proof_to_application(app, proof_config)
  proof_type = proof_config[:type]
  status_method = proof_config[:status_method]
  attachment_method = proof_config[:attachment_method]
  file_path = proof_config[:file_path]
  filename = proof_config[:filename]
  indent = proof_config[:indent] || '    '

  status_value = app.send(status_method)
  attachment = app.send(attachment_method)

  return unless valid_proof_status?(proof_type, status_value) && !attachment.attached?

  attach_proof_file(app, attachment, proof_type, file_path, filename, indent)
end

def valid_proof_status?(proof_type, status_value)
  valid_statuses = case proof_type
                   when :income_proof, :residency_proof
                     %w[approved rejected not_reviewed] # Include not_reviewed for test data
                   when :disability_certification
                     %w[received accepted]
                   else
                     []
                   end
  status_value.to_s.in?(valid_statuses)
end

def attach_proof_file(app, attachment, proof_type, file_path, filename, indent)
  seed_puts "#{indent}Attaching #{proof_type.to_s.humanize.downcase}..."
  full_file_path = Rails.root.join('test/fixtures/files', file_path)

  if File.exist?(full_file_path)
    attachment.attach(
      io: File.open(full_file_path),
      filename: filename,
      content_type: 'application/pdf'
    )
    app.save
    seed_success "#{indent}#{proof_type.to_s.humanize} attached"
  else
    seed_error "#{proof_type.to_s.humanize} file not found at #{full_file_path}"
  end
end

def verify_and_fix_attachment(app, attachment_method, proof_type, source_filename, fixed_files)
  attachment = app.send(attachment_method)

  return unless attachment.attached?

  blob = attachment.blob
  disk_key = blob.key
  disk_path = Rails.root.join('storage', disk_key[0, 2], disk_key[2, 2], disk_key)

  return if File.exist?(disk_path)

  seed_puts "  Fixing missing #{proof_type.to_s.humanize.downcase} for Application ##{app.id}..."

  dir_path = Rails.root.join('storage', disk_key[0, 2], disk_key[2, 2])
  FileUtils.mkdir_p(dir_path)

  source_path = Rails.root.join('test/fixtures/files', source_filename)
  FileUtils.cp(source_path, disk_path)

  fixed_files << proof_type
end

def clear_existing_data
  seed_puts 'Clearing existing data...'

  # Clear Session records first to avoid foreign key constraint violations
  seed_puts '  Clearing Session records...'
  Session.in_batches(of: 100).delete_all

  # Define the order of deletion to respect foreign key constraints.
  # Models with foreign keys (e.g., W9Review) must be cleared before the models
  # they point to (e.g., User).

  # Clear models with dependencies first. User is cleared last.
  [PrintQueueItem, SecureRequestForm, GuardianRelationship,
   ApplicationNote, TrainingSession, VoucherTransactionProduct, VoucherTransaction, Voucher,
   W9Review, Invoice, ApplicationStatusChange, Evaluation, ProofReview,
   Notification, RoleCapability, PolicyChange, EmailTemplate, Product, Event, Policy, Application].each do |model|
    seed_puts "  Clearing #{model.name} records..."
    # Delete records in small batches to avoid memory issues
    model.in_batches(of: 100).delete_all
  end

  seed_puts '  Clearing User records...'
  User.in_batches(of: 100).delete_all
end

def create_products_from_fixtures
  seed_puts 'Creating products from fixtures...'
  product_fixture_path = Rails.root.join('test/fixtures/products.yml')
  if File.exist?(product_fixture_path)
    product_data = YAML.load_file(product_fixture_path)
    product_data.each do |key, attributes|
      seed_puts "  Processing product #{key}..."
      # Assume that 'name' is unique for Product.
      Product.find_or_create_by(name: attributes['name']) do |product|
        clean_attributes = attributes.except('recommended_products', 'products_tried')
        product.assign_attributes(clean_attributes.transform_keys(&:to_sym))
      end
    end
    raise 'No products created' if Product.none?
  else
    seed_error "Products fixture not found at #{product_fixture_path}"
  end
end

def load_fixtures_data(users_map)
  seed_puts 'Loading fixtures in order...'
  load_applications_fixture(Rails.root.join('test/fixtures'), users_map)
  load_invoices_fixture(Rails.root.join('test/fixtures'), users_map)
end

def create_users_with_factories
  seed_puts 'Creating users with factories...'
  users_map = {}

  # SeedLookupHelpers expects these user keys.
  users_map['admin'] = create_user_with_factory(:admin, email: 'admin@example.com', first_name: 'Admin', last_name: 'User')
  users_map['confirmed_user'] = create_user_with_factory(:constituent, email: 'user@example.com', first_name: 'Test', last_name: 'User', email_verified: true)
  users_map['confirmed_user2'] = create_user_with_factory(:constituent, email: 'user2@example.com', first_name: 'Jane', last_name: 'Doe', email_verified: true)
  users_map['unconfirmed_user'] = create_user_with_factory(:constituent, email: 'unconfirmed@example.com', first_name: 'New', last_name: 'User', email_verified: false)
  users_map['trainer'] = create_user_with_factory(:trainer, email: 'trainer@example.com', first_name: 'Trainer', last_name: 'Person')
  users_map['evaluator'] = create_user_with_factory(:evaluator, email: 'evaluator@example.com', first_name: 'Evaluator', last_name: 'Person')
  users_map['certifying_professional'] = create_user_with_factory(:user, :certifying_professional, email: 'medical@example.com', first_name: 'Doctor', last_name: 'Smith')

  users_map['constituent_john'] = create_user_with_factory(:constituent, email: 'john.doe@example.com', first_name: 'John', last_name: 'Doe')
  users_map['constituent_jane'] = create_user_with_factory(:constituent, email: 'jane.doe@example.com', first_name: 'Jane', last_name: 'Doe')
  users_map['constituent_alex'] = create_user_with_factory(:constituent, email: 'alex.smith@example.com', first_name: 'Alex', last_name: 'Smith')
  users_map['constituent_rex'] = create_user_with_factory(:constituent, email: 'rex.canine@example.com', first_name: 'Rex', last_name: 'Canine')
  users_map['constituent_alice'] = create_user_with_factory(:constituent, email: 'alice.doe@example.com', first_name: 'Alice', last_name: 'Doe')
  users_map['constituent_kenneth'] = create_user_with_factory(:constituent, email: 'kenneth.klein@example.com', first_name: 'Kenneth', last_name: 'Klein')
  users_map['constituent_steven'] = create_user_with_factory(:constituent, email: 'steven.cooper@example.com', first_name: 'Steven', last_name: 'Cooper')
  users_map['constituent_wilbur'] = create_user_with_factory(:constituent, email: 'wilbur.wright@example.com', first_name: 'Wilbur', last_name: 'Wright')
  users_map['constituent_mark'] = create_user_with_factory(:constituent, email: 'mark.jones@example.com', first_name: 'Mark', last_name: 'Jones')

  users_map['vendor_ray'] = create_user_with_factory(:vendor_user, email: 'ray@testemail.com', first_name: 'Ray', last_name: 'Vendor')
  users_map['vendor_teltex'] = create_user_with_factory(:vendor_user, email: 'teltex@testemail.com', first_name: 'Teltex', last_name: 'Vendor')

  users_map
end

def create_user_with_factory(factory_name, *traits, **attributes)
  seed_puts "  Creating user with factory #{factory_name}..."
  user = FactoryBot.create(factory_name, *traits, **attributes)
  seed_success "  Created #{user.type || 'User'} #{user.email}"
  user
rescue StandardError => e
  seed_error "Failed to create user with factory #{factory_name}: #{e.message}"
  raise
end

def load_applications_fixture(fixtures_path, users_map)
  seed_puts 'Loading applications fixture via ActiveRecord models...'
  app_fixture_file = fixtures_path.join('applications.yml')

  if File.exist?(app_fixture_file)
    app_data = YAML.safe_load(ERB.new(File.read(app_fixture_file)).result, permitted_classes: [Date, DateTime, Time])
    app_data.each do |key, attributes|
      seed_puts "  Creating application #{key}..."
      # Map legacy fixture status "in_review" to valid enum "in_progress"
      attributes['status'] = 'in_progress' if attributes['status'] == 'in_review'
      # Map fixture submission_method values to valid enum keys
      attributes['submission_method'] = 'online' if attributes['submission_method'] == 'web'
      if attributes['user']
        user_key = attributes.delete('user')
        attributes['user_id'] = users_map[user_key]&.id
      end
      filtered_attributes = attributes.slice(*Application.attribute_names)
      app = Application.new(filtered_attributes)

      # Use update_columns for approved status to bypass validation requiring attachments
      # Proofs will be attached later in attach_files_to_applications
      if app.status == 'approved' || app.income_proof_status == 'approved' || app.residency_proof_status == 'approved'
        temp_status = app.status
        temp_income_status = app.income_proof_status
        temp_residency_status = app.residency_proof_status

        app.status = 'in_progress'
        app.income_proof_status = 'not_reviewed'
        app.residency_proof_status = 'not_reviewed'
        app.save!(validate: false)

        app.update_columns(
          status: Application.statuses[temp_status],
          income_proof_status: Application.income_proof_statuses[temp_income_status],
          residency_proof_status: Application.residency_proof_statuses[temp_residency_status]
        )
      else
        app.save!(validate: false)
      end
    end
  else
    seed_error "Applications fixture not found at #{app_fixture_file}"
  end
end

def load_invoices_fixture(fixtures_path, users_map)
  seed_puts 'Loading invoices fixture via ActiveRecord models...'
  invoice_fixture_file = fixtures_path.join('invoices.yml')
  if File.exist?(invoice_fixture_file)
    invoice_data = YAML.safe_load(ERB.new(File.read(invoice_fixture_file)).result, permitted_classes: [Date, DateTime, Time])
    invoices_map = {}
    invoice_data.each do |key, attributes|
      seed_puts "  Creating invoice #{key}..."
      # No status mapping needed; fixtures use Invoice enum keys
      if attributes['vendor']
        vendor_key = attributes.delete('vendor')
        attributes['vendor_id'] = users_map[vendor_key]&.id
      end
      filtered_attributes = attributes.slice(*Invoice.attribute_names)
      invoice = Invoice.new(filtered_attributes)
      invoice.save!(validate: false)
      invoices_map[key] = invoice
    end
  else
    seed_error "Invoices fixture not found at #{invoice_fixture_file}"
  end
end

def ensure_storage_directory
  seed_puts 'Ensuring storage directory exists...'
  storage_dir = Rails.root.join('storage')
  FileUtils.mkdir_p(storage_dir) unless storage_dir
end

def attach_files_to_applications
  seed_puts 'Attaching files to applications...'
  process_rex_canine_application
  process_other_applications
end

def process_rex_canine_application
  seed_puts 'Processing Rex Canine application specifically...'
  rex_app = Application.joins(:user).where(users: { first_name: 'Rex', last_name: 'Canine' }).first

  if rex_app
    seed_puts "Found Rex's application ##{rex_app.id}"
    seed_puts "  Current status - Income: #{rex_app.income_proof_status}, Residency: #{rex_app.residency_proof_status}"
    seed_puts "  Initial state - Income attached: #{rex_app.income_proof.attached?}, Residency attached: #{rex_app.residency_proof.attached?}"

    attach_rex_income_proof(rex_app)
    attach_rex_residency_proof(rex_app)
  else
    seed_error 'Could not find Rex Canine application'
  end
  rex_app
end

def attach_rex_income_proof(rex_app)
  return unless rex_app.income_proof_status == 'approved' && !rex_app.income_proof.attached?

  seed_puts '  Attaching income proof...'
  income_file_path = Rails.root.join('test/fixtures/files/income_proof.pdf')
  if File.exist?(income_file_path)
    rex_app.income_proof.attach(
      io: File.open(income_file_path),
      filename: 'income_proof.pdf',
      content_type: 'application/pdf'
    )
    # Validation still runs. On failure, save returns false and save! raises an exception.
    rex_app.save
    seed_success '  Income proof attached successfully'
  else
    seed_error "Income proof file not found at #{income_file_path}"
  end
end

def attach_rex_residency_proof(rex_app)
  return unless rex_app.residency_proof_status.in?(%w[approved rejected]) && !rex_app.residency_proof.attached?

  seed_puts '  Attaching residency proof...'
  residency_file_path = Rails.root.join('test/fixtures/files/residency_proof.pdf')
  if File.exist?(residency_file_path)
    rex_app.residency_proof.attach(
      io: File.open(residency_file_path),
      filename: 'residency_proof.pdf',
      content_type: 'application/pdf'
    )
    # Validation still runs. On failure, save returns false and save! raises an exception.
    rex_app.save
    seed_success '  Residency proof attached successfully'
  else
    seed_error "Residency proof file not found at #{residency_file_path}"
  end
end

def process_other_applications
  rex_app = Application.joins(:user).where(users: { first_name: 'Rex', last_name: 'Canine' }).first

  Application.find_each do |app|
    next if rex_app && app.id == rex_app.id

    if app.user.nil?
      seed_error "Skipping Application ##{app.id} - Missing user reference"
      next
    end

    seed_puts "  Processing Application ##{app.id} (#{app.user.email})"

    attach_proof_to_application(app, {
                                  type: :income_proof,
                                  status_method: :income_proof_status,
                                  attachment_method: :income_proof,
                                  file_path: 'income_proof.pdf',
                                  filename: 'income_proof.pdf'
                                })
    attach_proof_to_application(app, {
                                  type: :residency_proof,
                                  status_method: :residency_proof_status,
                                  attachment_method: :residency_proof,
                                  file_path: 'residency_proof.pdf',
                                  filename: 'residency_proof.pdf'
                                })
    attach_proof_to_application(app, {
                                  type: :disability_certification,
                                  status_method: :disability_certification_status,
                                  attachment_method: :disability_certification,
                                  file_path: 'disability_certification_valid.pdf',
                                  filename: 'disability_certification_valid.pdf'
                                })
  end
end

def verify_and_fix_missing_files
  seed_puts 'Verifying all application attachments...'

  Application.find_each do |app|
    fixed_files = []

    verify_and_fix_attachment(app, :income_proof, :income_proof, 'income_proof.pdf', fixed_files)
    verify_and_fix_attachment(app, :residency_proof, :residency_proof, 'residency_proof.pdf', fixed_files)
    verify_and_fix_attachment(app, :disability_certification, :disability_certification, 'disability_certification_valid.pdf', fixed_files)

    seed_success "  Fixed #{fixed_files.size} missing files for Application ##{app.id}: #{fixed_files.join(', ')}" if fixed_files.any?
  end
end

seed_puts "SEEDING STARTED at #{Time.current}"
begin
  ActiveRecord::Base.transaction do
    seed_puts 'Clearing existing data...'
    clear_existing_data

    seed_puts 'Creating products from fixtures...'
    create_products_from_fixtures

    seed_puts 'Creating users with factories...'
    users_map = create_users_with_factories

    # Tests create the system audit administrator themselves, so the seeded administrator owns the baseline records there.
    baseline_actor = Rails.env.test? ? users_map['admin'] : Baseline::Accounts.provision_system_audit_actor!

    seed_puts 'Creating policies and feature flags...'
    Baseline::Policies.reset!(actor: baseline_actor)
    Baseline::FeatureFlags.reset!(actor: baseline_actor)

    seed_puts 'Loading fixture data (applications, invoices)...'
    load_fixtures_data(users_map)

    seed_puts 'Seeding email templates...'
    EmailTemplates::Catalog.replace!(actor: baseline_actor)

    seed_puts 'Seeding rejection reasons...'
    Baseline::RejectionReasons.reset!(actor: baseline_actor)

    seed_puts 'Ensuring storage directory exists...'
    ensure_storage_directory

    seed_puts 'Attaching files to applications...'
    attach_files_to_applications

    seed_puts 'Verifying and fixing missing files...'
    verify_and_fix_missing_files

    if Rails.env.development?
      seed_puts 'Creating varied development applications...'
      require_relative 'seeds/development_applications'
      Seeds::DevelopmentApplications.new(admin: User.find_by_email('admin@example.com')).call
    end
  end
rescue StandardError => e
  Rails.logger.debug { "SEEDING FAILED: #{e.message}" }
  seed_error "Seeding failed: #{e.message}"
  Rails.logger.debug 'Backtrace:'
  e.backtrace.first(10).each { |line| Rails.logger.debug line }
  raise e
else
  seed_puts 'SEEDING SUMMARY:'
  seed_puts "   Users: #{User.count}"
  seed_puts "   Applications: #{Application.count}"
  seed_puts "   Products: #{Product.count}"
  seed_puts "   Policies: #{Policy.count}"
  seed_puts "   Feature Flags: #{FeatureFlag.count}"
  seed_puts "   Email Templates: #{EmailTemplate.count}"
  seed_puts "   Rejection Reasons: #{RejectionReason.count}"
  seed_puts "   Invoices: #{Invoice.count}"
  seed_puts "SEEDING COMPLETED SUCCESSFULLY at #{Time.current}!"
  Rails.logger.debug 'Seeding completed successfully!'
end
