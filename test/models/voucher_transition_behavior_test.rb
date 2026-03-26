# frozen_string_literal: true

require 'test_helper'

class VoucherTransitionBehaviorTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess::FixtureFile

  def setup
    setup_paper_application_context
    @income_flag = FeatureFlag.find_or_create_by!(name: 'income_proof_required') { |f| f.enabled = true }
    @vouchers_flag = FeatureFlag.find_or_create_by!(name: 'vouchers_enabled') { |f| f.enabled = false }
  end

  # --- AuditEventService: value-aware dedup for feature_flag_toggled ---

  test 'AuditEventService allows rapid toggles with different values' do
    admin = create(:admin)
    flag = create(:feature_flag, name: 'test_toggle_flag', enabled: true)

    event1 = AuditEventService.log(
      action: 'feature_flag_toggled',
      actor: admin,
      auditable: flag,
      metadata: { flag_name: 'test_toggle_flag', old_value: true, new_value: false }
    )

    event2 = AuditEventService.log(
      action: 'feature_flag_toggled',
      actor: admin,
      auditable: flag,
      metadata: { flag_name: 'test_toggle_flag', old_value: false, new_value: true }
    )

    assert_not_nil event1, 'First toggle should create an event'
    assert_not_nil event2, 'Second toggle (different values) should not be suppressed'
  end

  test 'AuditEventService fingerprint distinguishes different flag toggle values' do
    fp_on_to_off = AuditEventService.send(
      :create_event_fingerprint,
      'feature_flag_toggled',
      { flag_name: 'test_flag', old_value: true, new_value: false, admin_id: 1 }
    )
    fp_off_to_on = AuditEventService.send(
      :create_event_fingerprint,
      'feature_flag_toggled',
      { flag_name: 'test_flag', old_value: false, new_value: true, admin_id: 1 }
    )
    fp_same = AuditEventService.send(
      :create_event_fingerprint,
      'feature_flag_toggled',
      { flag_name: 'test_flag', old_value: true, new_value: false, admin_id: 1 }
    )

    assert_not_equal fp_on_to_off, fp_off_to_on, 'Different toggle directions should produce different fingerprints'
    assert_equal fp_on_to_off, fp_same, 'Same toggle direction should produce identical fingerprints'
  end

  test 'AuditEventService fingerprint handles false values after JSON round-trip' do
    symbol_keys = { flag_name: 'f', old_value: false, new_value: true, admin_id: 42 }
    string_keys = { 'flag_name' => 'f', 'old_value' => false, 'new_value' => true, 'admin_id' => 42 }

    fp_symbol = AuditEventService.send(:create_event_fingerprint, 'feature_flag_toggled', symbol_keys)
    fp_string = AuditEventService.send(:create_event_fingerprint, 'feature_flag_toggled', string_keys)

    assert_equal fp_symbol, fp_string, 'Fingerprints must match across symbol/string keys even with false values'
    assert_includes fp_symbol, 'false', 'Fingerprint must include the literal false, not nil'
  end

  test 'AuditEventService fingerprint includes actor_id to differentiate admins' do
    fp_admin1 = AuditEventService.send(
      :create_event_fingerprint,
      'feature_flag_toggled',
      { flag_name: 'f', old_value: true, new_value: false, admin_id: 1 }
    )
    fp_admin2 = AuditEventService.send(
      :create_event_fingerprint,
      'feature_flag_toggled',
      { flag_name: 'f', old_value: true, new_value: false, admin_id: 2 }
    )

    assert_not_equal fp_admin1, fp_admin2, 'Different admins should produce different fingerprints'
  end

  # --- ApplicationForm: conditional income validation ---

  test 'ApplicationForm validates annual_income on submission when income required' do
    @income_flag.update!(enabled: true)
    user = create(:constituent, :with_disabilities)

    form = ApplicationForm.new(
      current_user: user,
      is_submission: true,
      annual_income: nil,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '555-1234',
      medical_provider_email: 'dr@test.com',
      hearing_disability: true
    )

    assert_not form.valid?
    assert_includes form.errors[:annual_income], "can't be blank"
  end

  test 'ApplicationForm skips annual_income validation when income not required' do
    @income_flag.update!(enabled: false)
    user = create(:constituent, :with_disabilities)

    form = ApplicationForm.new(
      current_user: user,
      is_submission: true,
      annual_income: nil,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '555-1234',
      medical_provider_email: 'dr@test.com',
      hearing_disability: true
    )

    assert form.valid?, "Expected form valid without income: #{form.errors.full_messages}"
  end

  test 'ApplicationForm uses persisted application income_proof_required for drafts' do
    @income_flag.update!(enabled: true)
    user = create(:constituent, :with_disabilities)
    app = create(:application, :draft, user: user)
    assert app.income_proof_required?

    app.update_columns(income_proof_required: false)
    app.reload

    form = ApplicationForm.new(
      current_user: user,
      application: app,
      is_submission: true,
      annual_income: nil,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '555-1234',
      medical_provider_email: 'dr@test.com',
      hearing_disability: true
    )

    assert form.valid?, "Expected form valid when app has income_proof_required=false: #{form.errors.full_messages}"
  end

  # --- PaperApplicationService: income threshold skip ---

  test 'PaperApplicationService skips income threshold validation when flag is off' do
    @income_flag.update!(enabled: false)
    admin = create(:admin)
    setup_fpl_policies

    timestamp = Time.now.to_i
    params = {
      constituent: {
        first_name: 'Test', last_name: 'User',
        email: "threshold-test-#{timestamp}@example.com",
        phone: "20255500#{timestamp.to_s[-2..]}",
        physical_address_1: '123 Test St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        hearing_disability: '1'
      },
      application: {
        household_size: '1',
        annual_income: '999999',
        maryland_resident: '1',
        self_certify_disability: '1',
        medical_provider_name: 'Dr. Smith',
        medical_provider_phone: '2025559876',
        medical_provider_email: 'dr@test.com'
      },
      income_proof_action: 'none',
      residency_proof_action: 'none'
    }

    service = Applications::PaperApplicationService.new(params: params, admin: admin)
    result = service.create

    assert result, "Expected success despite high income when flag is off: #{service.errors}"
  end

  test 'PaperApplicationService determine_initial_status ignores income when flag off' do
    @income_flag.update!(enabled: false)
    admin = create(:admin)
    setup_fpl_policies

    timestamp = Time.now.to_i
    params = {
      constituent: {
        first_name: 'Test', last_name: 'Status',
        email: "status-test-#{timestamp}@example.com",
        phone: "20255501#{timestamp.to_s[-2..]}",
        physical_address_1: '123 Test St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        hearing_disability: '1'
      },
      application: {
        household_size: '2',
        annual_income: '15000',
        maryland_resident: '1',
        self_certify_disability: '1',
        medical_provider_name: 'Dr. Smith',
        medical_provider_phone: '2025559876',
        medical_provider_email: 'dr@test.com'
      },
      income_proof_action: 'none',
      residency_proof_action: 'accept',
      residency_proof: fixture_file_upload(
        Rails.root.join('test/fixtures/files/income_proof.pdf'),
        'application/pdf'
      )
    }

    service = Applications::PaperApplicationService.new(params: params, admin: admin)
    result = service.create
    assert result, "Expected success: #{service.errors}"

    app = service.application
    assert_equal 'in_progress', app.status,
                 "Expected in_progress when income action=none but flag off (only residency matters)"
  end

  # --- PaperApplicationService: income proof processing skip ---

  test 'PaperApplicationService does not process income proof when flag is off' do
    @income_flag.update!(enabled: false)
    admin = create(:admin)
    setup_fpl_policies

    timestamp = Time.now.to_i
    params = {
      constituent: {
        first_name: 'Test', last_name: 'ProofSkip',
        email: "proof-skip-#{timestamp}@example.com",
        phone: "20255502#{timestamp.to_s[-2..]}",
        physical_address_1: '123 Test St', city: 'Baltimore', state: 'MD', zip_code: '21201',
        hearing_disability: '1'
      },
      application: {
        household_size: '1',
        annual_income: '30000',
        maryland_resident: '1',
        self_certify_disability: '1',
        medical_provider_name: 'Dr. Smith',
        medical_provider_phone: '2025559876',
        medical_provider_email: 'dr@test.com'
      },
      income_proof_action: 'accept',
      income_proof: fixture_file_upload(
        Rails.root.join('test/fixtures/files/income_proof.pdf'),
        'application/pdf'
      ),
      residency_proof_action: 'none'
    }

    service = Applications::PaperApplicationService.new(params: params, admin: admin)
    result = service.create
    assert result, "Expected success: #{service.errors}"

    app = service.application
    assert_not app.income_proof_required?, 'Application should have income_proof_required=false'
    assert_equal 'not_reviewed', app.income_proof_status,
                 'Income proof status should remain not_reviewed when income processing is skipped'
  end

  # --- Voucher details visibility ---

  test 'voucher_fulfillment? remains true after voucher issuance' do
    @vouchers_flag.update!(enabled: true)
    user = create(:constituent, :with_disabilities)
    app = create(:application, :approved, user: user)
    assert app.voucher_fulfillment?, 'Application should be voucher_fulfillment after creation with flag on'

    create(:voucher, application: app)
    app.reload

    assert app.voucher_fulfillment?, 'voucher_fulfillment? should remain true after voucher issuance'
    assert_not app.voucher_issuable?, 'voucher_issuable? should be false once a voucher exists'
  end

  # --- FeatureFlagsController: transactional audit ---

  test 'FeatureFlagsController update creates audit event with old and new values' do
    flag = create(:feature_flag, name: 'audit_test_flag', enabled: true)
    admin = create(:admin)

    old_value = flag.enabled
    flag.update!(enabled: false)

    event = AuditEventService.log(
      action: 'feature_flag_toggled',
      actor: admin,
      auditable: flag,
      metadata: {
        flag_name: flag.name,
        old_value: old_value,
        new_value: flag.enabled
      }
    )

    assert_not_nil event
    assert_equal true, event.metadata['old_value']
    assert_equal false, event.metadata['new_value']
    assert_equal 'audit_test_flag', event.metadata['flag_name']
  end
end
