# frozen_string_literal: true

require 'test_helper'

class IcanconnectEligibilityTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    FeatureFlag.disable!(:vouchers_enabled)
  end

  test 'normal proof approval establishes ICC eligibility without another review' do
    application = create(:application, :draft, :with_all_proofs, application_date: Date.current,
                                                                 terms_accepted: true, information_verified: true,
                                                                 disability_information_release_authorized: true,
                                                                 income_proof_status: :approved, residency_proof_status: :approved,
                                                                 id_proof_status: :approved, disability_certification_status: :approved)
    assert_not application.icanconnect_eligible?

    application.submit!(actor: @admin)
    application.reconcile_workflow_state!(actor: @admin, trigger: :test)

    assert application.reload.status_approved?
    assert application.icanconnect_eligible?
    assert_equal 1, application.status_changes.where(to_status: 'approved').count
    assert application.equipment_procurement_eligible?
    assert Application.equipment_procurement_eligible.exists?(application.id)
  end

  test 'ICC uses the constituent hearing and vision disabilities and approved certificate' do
    application = qualified_application
    assert application.icanconnect_eligible?

    application.user.vision_disability = false
    assert_not application.icanconnect_eligible?

    application.user.vision_disability = true
    application.user.hearing_disability = false
    assert_not application.icanconnect_eligible?

    application.user.hearing_disability = true
    application.disability_certification_status = :received
    assert_not application.icanconnect_eligible?

    application.disability_certification_status = :approved
    application.disability_certification.detach
    assert_not application.icanconnect_eligible?
  end

  test 'ICC still needs approved income evidence when MAT makes income optional' do
    FeatureFlag.enable!(:vouchers_enabled)
    application = create(:application, :approved, :with_residency_proof, :with_id_proof, :with_disability_certification,
                         application_date: Date.current, disability_certification_status: :approved, income_proof_status: :not_reviewed)

    assert application.status_approved?
    assert_not application.income_proof_required?
    assert_not application.icanconnect_eligible?
    assert application.service_window_active?

    qualified = qualified_application
    assert_not qualified.income_proof_required?
    assert qualified.icanconnect_eligible?

    qualified.income_proof_status = :not_reviewed
    assert_not qualified.icanconnect_eligible?
    qualified.income_proof_status = :approved
    qualified.income_proof.detach
    assert_not qualified.icanconnect_eligible?
    assert qualified.status_approved?
  end

  test 'ICC eligibility removes the training count limit without a second approval state' do
    Policy.stubs(:max_training_sessions).returns(1)
    trainer = create(:trainer)
    application = qualified_application(assigned_trainer: trainer)
    create(:training_session, :completed, application: application, trainer: trainer)

    assert application.unlimited_training_sessions?
    assert_nil application.remaining_training_sessions
    assert_not application.training_session_quota_exhausted?
    assert application.training_capacity_available?
    assert build(:training_session, application: application, trainer: trainer).valid?

    application.user.vision_disability = false
    assert_not application.unlimited_training_sessions?
    assert_equal 0, application.remaining_training_sessions
    assert application.training_session_quota_exhausted?
    assert_not application.training_capacity_available?
  end

  test 'ICC eligibility does not create a different application service window' do
    application = qualified_application(application_date: 8.years.ago)

    assert application.icanconnect_eligible?
    assert_not application.service_window_active?
    assert_not Applications::TrainingRequestService.new(application: application, current_user: application.user).call.success?
  end

  private

  def qualified_application(**attributes)
    create(:application, :completed, :with_all_proofs, application_date: Date.current, **attributes)
  end
end
