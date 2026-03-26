# frozen_string_literal: true

require 'test_helper'

class ApplicationWorkflowPredicatesTest < ActiveSupport::TestCase
  def setup
    setup_paper_application_context
    @income_flag = FeatureFlag.find_or_create_by!(name: 'income_proof_required') { |f| f.enabled = true }
    @vouchers_flag = FeatureFlag.find_or_create_by!(name: 'vouchers_enabled') { |f| f.enabled = false }
  end

  # --- stamp_workflow_defaults! ---

  test 'stamp_workflow_defaults! sets equipment when vouchers_enabled is off' do
    @vouchers_flag.update!(enabled: false)
    @income_flag.update!(enabled: true)
    app = create(:application, :in_progress)
    assert app.fulfillment_type_equipment?
    assert app.income_proof_required?
  end

  test 'stamp_workflow_defaults! sets voucher when vouchers_enabled is on' do
    @vouchers_flag.update!(enabled: true)
    @income_flag.update!(enabled: false)
    app = create(:application, :in_progress)
    assert app.fulfillment_type_voucher?
    assert_not app.income_proof_required?
  end

  test 'stamp_workflow_defaults! is unconditional and overrides any pre-set values' do
    @vouchers_flag.update!(enabled: true)
    @income_flag.update!(enabled: true)
    app = Application.new(fulfillment_type: :equipment, income_proof_required: false)
    app.assign_attributes(
      user: create(:constituent, :with_disabilities),
      status: :in_progress,
      application_date: 4.years.ago,
      maryland_resident: true,
      self_certify_disability: true,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '555-1234',
      medical_provider_email: 'dr@test.com'
    )
    app.save!
    assert app.fulfillment_type_voucher?, "Expected voucher, got #{app.fulfillment_type}"
    assert app.income_proof_required?, 'Expected income_proof_required to be true'
  end

  # --- scrub_income_fields ---

  test 'scrub_income_fields nils out income data on new record when income is off' do
    @income_flag.update!(enabled: false)
    app = create(:application, :in_progress)
    assert_nil app.annual_income
    assert_nil app.household_size
  end

  test 'scrub_income_fields preserves income data when income is on' do
    @income_flag.update!(enabled: true)
    app = create(:application, :in_progress)
    assert_not_nil app.annual_income
    assert_not_nil app.household_size
  end

  test 'scrub_income_fields works on draft status updates' do
    @income_flag.update!(enabled: true)
    app = create(:application, :draft)
    assert_not_nil app.household_size

    app.update_columns(income_proof_required: false)
    app.household_size = 5
    app.annual_income = 30_000
    app.valid?
    assert_nil app.household_size
    assert_nil app.annual_income
  end

  # --- income_collection_enabled? ---

  test 'income_collection_enabled? returns income_proof_required for persisted records' do
    @income_flag.update!(enabled: true)
    app = create(:application, :in_progress)
    assert app.income_collection_enabled?

    app.update_columns(income_proof_required: false)
    app.reload
    assert_not app.income_collection_enabled?
  end

  test 'income_collection_enabled? checks feature flag for new records' do
    @income_flag.update!(enabled: true)
    app = Application.new
    assert app.income_collection_enabled?

    @income_flag.update!(enabled: false)
    assert_not app.income_collection_enabled?
  end

  # --- Fulfillment predicates ---

  test 'voucher_fulfillment? and equipment_fulfillment?' do
    @vouchers_flag.update!(enabled: false)
    app = create(:application, :in_progress)
    assert app.equipment_fulfillment?
    assert_not app.voucher_fulfillment?

    app = create(:application, :in_progress, :voucher_fulfillment)
    assert app.voucher_fulfillment?
    assert_not app.equipment_fulfillment?
  end

  # --- residency_proof_required? ---

  test 'residency_proof_required? always returns true' do
    app = Application.new
    assert app.residency_proof_required?
  end

  # --- required_proofs_approved? ---

  test 'required_proofs_approved? requires both proofs when income is required' do
    app = create(:application, :in_progress)
    assert app.income_proof_required?
    assert_not app.required_proofs_approved?

    app.update_columns(residency_proof_status: Application.residency_proof_statuses[:approved])
    app.reload
    assert_not app.required_proofs_approved?

    app.update_columns(income_proof_status: Application.income_proof_statuses[:approved])
    app.reload
    assert app.required_proofs_approved?
  end

  test 'required_proofs_approved? only needs residency when income is not required' do
    app = create(:application, :in_progress, :income_not_required)
    app.reload
    assert_not app.income_proof_required?
    assert_not app.required_proofs_approved?

    app.update_columns(residency_proof_status: Application.residency_proof_statuses[:approved])
    app.reload
    assert app.required_proofs_approved?
  end

  # --- voucher_issuable? ---

  test 'voucher_issuable? requires voucher fulfillment, approved status, and cert' do
    app = create(:application, :completed, :voucher_fulfillment)
    app.reload
    assert app.voucher_issuable?
  end

  test 'voucher_issuable? returns false for equipment fulfillment' do
    app = create(:application, :completed)
    assert app.equipment_fulfillment?
    assert_not app.voucher_issuable?
  end

  test 'voucher_issuable? returns false when voucher already exists' do
    app = create(:application, :completed, :voucher_fulfillment)
    app.reload
    app.vouchers.create!(
      code: "TEST-#{SecureRandom.hex(4)}",
      initial_value: 100,
      remaining_value: 100,
      status: :active
    )
    assert_not app.voucher_issuable?
  end

  # --- with_proofs_needing_review scope ---

  test 'with_proofs_needing_review includes income not_reviewed only when income required' do
    app_with_income = create(:application, :in_progress)
    app_without_income = create(:application, :in_progress, :income_not_required)

    app_with_income.update_columns(
      residency_proof_status: Application.residency_proof_statuses[:approved],
      income_proof_status: Application.income_proof_statuses[:not_reviewed]
    )
    app_without_income.update_columns(
      residency_proof_status: Application.residency_proof_statuses[:approved],
      income_proof_status: Application.income_proof_statuses[:not_reviewed]
    )

    results = Application.with_proofs_needing_review
    assert_includes results, app_with_income
    assert_not_includes results, app_without_income
  end

  test 'with_proofs_needing_review includes residency not_reviewed regardless' do
    app = create(:application, :in_progress, :income_not_required)
    app.update_columns(residency_proof_status: Application.residency_proof_statuses[:not_reviewed])

    results = Application.with_proofs_needing_review
    assert_includes results, app
  end

  # --- VoucherManagement#can_create_voucher? ---

  test 'can_create_voucher? requires voucher fulfillment' do
    app = create(:application, :completed)
    assert app.equipment_fulfillment?
    assert_not app.can_create_voucher?
  end

  test 'can_create_voucher? returns true for voucher fulfillment with approved status and cert' do
    app = create(:application, :completed, :voucher_fulfillment)
    app.reload
    assert app.can_create_voucher?
  end

  # --- all_requirements_met? uses required_proofs_approved? ---

  test 'all_requirements_met? skips income when income_proof_required is false' do
    app = create(:application, :in_progress, :income_not_required)
    app.update_columns(
      residency_proof_status: Application.residency_proof_statuses[:approved],
      medical_certification_status: Application.medical_certification_statuses[:approved]
    )
    app.reload

    assert app.send(:all_requirements_met?)
  end

  # --- ProofReviewer auto-approval without income ---

  test 'ProofReviewer auto-approves when income not required and residency approved' do
    app = create(:application, :in_progress, :income_not_required)
    app.update_columns(medical_certification_status: Application.medical_certification_statuses[:approved])
    app.residency_proof.attach(
      io: StringIO.new('test residency proof'),
      filename: 'residency.pdf',
      content_type: 'application/pdf'
    )
    admin = create(:admin)
    app.stubs(:purge_rejected_proof).returns(true)

    reviewer = Applications::ProofReviewer.new(app, admin)
    reviewer.review(proof_type: :residency, status: :approved)

    app.reload
    assert app.status_approved?, "Expected auto-approval, got #{app.status}"
    assert app.status_changes.exists?(to_status: 'approved'),
           'Expected ApplicationStatusChange record for auto-approval'
  end

  test 'ProofReviewer creates audit event on auto-approval' do
    app = create(:application, :in_progress, :income_not_required)
    app.update_columns(medical_certification_status: Application.medical_certification_statuses[:approved])
    app.residency_proof.attach(
      io: StringIO.new('test residency proof'),
      filename: 'residency.pdf',
      content_type: 'application/pdf'
    )
    admin = create(:admin)
    app.stubs(:purge_rejected_proof).returns(true)

    reviewer = Applications::ProofReviewer.new(app, admin)

    assert_difference -> { Event.where(action: 'application_auto_approved').count }, 1 do
      reviewer.review(proof_type: :residency, status: :approved)
    end
  end

  # --- ProofConsistencyValidation respects income_proof_required ---

  test 'proof consistency skips income proof check when income not required' do
    app = create(:application, :in_progress, :income_not_required)
    app.update_columns(
      income_proof_status: Application.income_proof_statuses[:approved],
      submission_method: Application.submission_methods[:online]
    )
    app.reload

    assert app.valid?, "Expected valid despite no income proof attached: #{app.errors.full_messages}"
  end

  # --- ProofManageable#require_proof_attachments ---

  test 'require_proof_attachments skips income proof when not required' do
    ENV['REQUIRE_PROOF_VALIDATIONS'] = 'true'
    app = create(:application, :in_progress, :income_not_required)
    app.residency_proof.attach(
      io: StringIO.new('residency proof'),
      filename: 'residency.pdf',
      content_type: 'application/pdf'
    )

    assert app.valid?, "Expected valid without income proof: #{app.errors.full_messages}"
  ensure
    ENV.delete('REQUIRE_PROOF_VALIDATIONS')
  end

  # --- pending_proof_types ---

  test 'pending_proof_types omits income when not required' do
    app = create(:application, :in_progress, :income_not_required)
    app.update_columns(
      income_proof_status: Application.income_proof_statuses[:not_reviewed],
      residency_proof_status: Application.residency_proof_statuses[:not_reviewed]
    )
    app.reload

    assert_not_includes app.send(:pending_proof_types), 'income'
    assert_includes app.send(:pending_proof_types), 'residency'
  end

  test 'pending_proof_types includes income when required' do
    app = create(:application, :in_progress)
    assert app.income_proof_required?
    app.update_columns(
      income_proof_status: Application.income_proof_statuses[:not_reviewed],
      residency_proof_status: Application.residency_proof_statuses[:not_reviewed]
    )
    app.reload

    assert_includes app.send(:pending_proof_types), 'income'
    assert_includes app.send(:pending_proof_types), 'residency'
  end
end
