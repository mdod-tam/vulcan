# frozen_string_literal: true

require 'test_helper'

class ApplicationProviderInfoRequestsTest < ActiveSupport::TestCase
  test 'pending provider info scope remains composable with joins' do
    matching_application = create(
      :application,
      residency_proof_status: :approved,
      id_proof_status: :approved,
      income_proof_required: false
    )
    # Seed a legacy/incomplete row for this read-only queue scope. This bypasses
    # provider contact validations and Application save callbacks for status,
    # review, audit, and timestamp side effects, none of which are under test here.
    matching_application.update_columns(
      income_proof_required: false,
      medical_provider_name: '',
      medical_provider_phone: '',
      medical_provider_email: ''
    )
    create(
      :application,
      residency_proof_status: :approved,
      id_proof_status: :approved,
      income_proof_required: false
    )

    result = Application.joins(:user).pending_provider_info

    assert_includes result, matching_application
  end

  # -----------------------------------------------------------------------
  # pending_provider_info alignment regression coverage
  # The scope must stay aligned with Application#required_proofs_approved? and
  # the plan's definition of proof prerequisites.
  # -----------------------------------------------------------------------

  # Application model callbacks recalculate income_proof_required from income/household
  # data on save. Use update_columns after creation (as the existing test does) to set
  # the exact proof-state combination needed without triggering those callbacks.

  test 'pending_provider_info includes application when income is not required and provider info is missing' do
    app = create(:application, residency_proof_status: :approved, id_proof_status: :approved)
    app.update_columns(
      income_proof_required: false,
      medical_provider_name: '', medical_provider_phone: '', medical_provider_email: ''
    )

    assert_includes Application.pending_provider_info, app
  end

  test 'pending_provider_info excludes application when income is required but not approved' do
    app = create(:application, residency_proof_status: :approved, id_proof_status: :approved)
    app.update_columns(
      income_proof_required: true,
      income_proof_status: Application.income_proof_statuses[:not_reviewed],
      medical_provider_name: '', medical_provider_phone: '', medical_provider_email: ''
    )

    refute_includes Application.pending_provider_info, app
  end

  test 'pending_provider_info includes application when income is required and approved' do
    app = create(:application, residency_proof_status: :approved, id_proof_status: :approved)
    app.update_columns(
      income_proof_required: true,
      income_proof_status: Application.income_proof_statuses[:approved],
      medical_provider_name: '', medical_provider_phone: '', medical_provider_email: ''
    )

    assert_includes Application.pending_provider_info, app
  end

  # Regression: the scope requires id_proof_status approved. If id_proof is not
  # approved the application must not appear in the queue.
  test 'pending_provider_info excludes application when id_proof is not approved' do
    app = create(:application, residency_proof_status: :approved)
    app.update_columns(
      id_proof_status: Application.id_proof_statuses[:not_reviewed],
      income_proof_required: false,
      medical_provider_name: '', medical_provider_phone: '', medical_provider_email: ''
    )

    refute_includes Application.pending_provider_info, app
  end

  test 'pending_provider_info excludes application when provider info is complete' do
    app = create(:application, residency_proof_status: :approved, id_proof_status: :approved)
    app.update_columns(income_proof_required: false)
    # Provider info fields are populated by the factory; scope must exclude this app.
    refute_includes Application.pending_provider_info, app
  end

  test 'pending_provider_info excludes application when only residency is approved but id_proof is rejected' do
    app = create(:application, residency_proof_status: :approved)
    app.update_columns(
      id_proof_status: Application.id_proof_statuses[:rejected],
      income_proof_required: false,
      medical_provider_name: '', medical_provider_phone: '', medical_provider_email: ''
    )

    refute_includes Application.pending_provider_info, app
  end
end
