# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/seeds/development_applications'

class DevelopmentApplicationsTest < ActiveSupport::TestCase
  include IcanconnectTestSupport

  setup do
    start_icanconnect!
    Rails.env.stubs(:development?).returns(true)
    @admin = User.find_by_email('admin@example.com')
  end

  test 'demo reseeding removes registration and contact authority before rebuilding users' do
    user = create(:constituent)
    session_record = user.sessions.create!(ip_address: '127.0.0.1', user_agent: 'Seed cleanup regression')
    verification = RegistrationVerification.create!(
      email: user.email, locale: 'en', expires_at: RegistrationVerification::LIFETIME.from_now,
      consumed_at: Time.current, created_user: user
    )
    change = ContactChangeRequest.create!(
      user: user, session: session_record, kind: 'email', old_value: user.email,
      proposed_value: 'seed-cleanup-contact@example.test', security_version: user.security_version,
      expires_at: ContactChangeRequest::LIFETIME.from_now
    )

    Rails.application.load_seed

    assert_not ContactChangeRequest.exists?(change.id)
    assert_not RegistrationVerification.exists?(verification.id)
    assert_not Session.exists?(session_record.id)
    assert_not User.exists?(user.id)
    assert_predicate User.find_by_email('admin@example.com'), :admin?

    submitted = Application.where.not(status: :draft).with_attached_id_proof.to_a
    assert_operator submitted.size, :>, 0
    assert(submitted.all? { |application| application.id_proof.attached? })
    assert_equal 0, Applications::ReviewQueueSummary.new.call.fetch(:providers).unknown_dates

    pipeline = Applications::ApprovedPipeline.new(Application.equipment_procurement_eligible.to_a)
    stages = pipeline.rows.map(&:stage)
    Equipment::FulfillmentStage::DEFINITIONS.each { |definition| assert_includes stages, definition.key }
    assert(pipeline.summaries(:equipment).all? { |summary| summary.unknown_dates.zero? })
    assert Application.approved_awaiting_training.exists?

    jane = User.find_by_email('user2@example.com')
    other_jane = User.find_by_email('jane.doe@example.com')
    assert_not_equal jane.id, other_jane.id
    assert_equal 'Jane Doe', jane.full_name
    assert_equal jane.full_name, other_jane.full_name
    assert jane.applications.sole.status_approved?
    assert other_jane.applications.sole.status_archived?
    assert_equal 1, Application.blocking_new_submission.where(user: [jane, other_jane]).count
  end

  test 'the awaiting certification fixture has its own constituent instead of reusing approved Jane' do
    application = Application.find_by!(certifying_professional_email: 'awaiting.provider@example.com')
    assert_equal 'awaiting.certification@example.com', application.user.email
    assert_not_equal User.find_by_email('user2@example.com').id, application.user_id
    assert application.status_awaiting_dcf?
    assert_equal application, application.user.applications.sole
  end

  test 'development examples do not consume real upload allocation quotas' do
    stub_const(DocumentScans::Stager, :GLOBAL_DAILY_LIMIT, 0) do
      applications = Seeds::DevelopmentApplications.new(admin: @admin).call

      assert_equal Seeds::DevelopmentApplications::PROFILES.size, applications.size
      assert(applications.any? { |application| application.income_proof.attached? })
      assert applications.select { |application| application.income_proof.attached? }.all? do |application|
        DocumentScan.cleared?(application.income_proof.blob)
      end
    end
  end

  test 'the development seed class refuses other environments before writing records' do
    Rails.env.stubs(:development?).returns(false)

    assert_no_difference ['Application.count', 'User.count', 'DocumentScan.count', 'ActiveStorage::Blob.count'] do
      assert_raises(RuntimeError) { Seeds::DevelopmentApplications.new(admin: @admin).call }
    end
  end

  test 'fixture clearance cannot run in production even if its helper is loaded' do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('fixture'), filename: 'fixture.pdf')
    Rails.stubs(:env).returns(ActiveSupport::EnvironmentInquirer.new('production'))

    assert_no_difference 'DocumentScan.count' do
      assert_raises(RuntimeError) { DocumentScanFixtures.clear!(blob, user: @admin) }
    end
  end

  test 'equipment gallery covers lifecycle and actionable review queues with truthful ownership' do
    FeatureFlag.find_by!(name: 'vouchers_enabled').update!(enabled: false)
    applications = Seeds::DevelopmentApplications.new(admin: @admin).call
    by_email = applications.index_by { |application| application.user.email }

    assert_equal Application.statuses.keys.sort, applications.map(&:status).uniq.sort
    assert applications.all?(&:valid?)
    assert applications.all?(&:equipment_fulfillment?)
    assert applications.all?(&:income_proof_required?)
    assert(applications.reject(&:status_draft?).all? { |application| application.id_proof.attached? })

    draft = by_email.fetch('maya.brooks@example.com')
    assert_not draft.income_proof.attached?
    assert_empty draft.status_changes

    pending = by_email.fetch('lucia.rivera@example.com')
    assert pending.needs_proof_type_review?(:residency)
    assert_equal 'es', pending.user.locale

    partial = by_email.fetch('walter.chen@example.com')
    assert partial.income_proof_status_approved?
    assert partial.residency_proof_status_approved?
    assert partial.id_proof_status_not_reviewed?
    assert partial.id_proof.attached?

    rejected = by_email.fetch('omar.hassan@example.com')
    assert rejected.income_proof_status_rejected?
    assert rejected.id_proof_status_approved?
    assert_equal 'The income document is unreadable. Please upload a clearer copy.', rejected.proof_reviews.find_by!(proof_type: :income).rejection_reason

    received = by_email.fetch('james.wilson@example.com')
    assert received.status_awaiting_dcf?
    assert received.disability_certification_status_received?
    assert received.disability_certification.attached?
    assert received.proof_reviews.all?(&:submission_method_email?)
    assert by_email.fetch('elena.garcia@example.com').disability_certification_status_rejected?

    approved = by_email.fetch('samuel.reed@example.com')
    assert approved.required_proofs_approved?
    assert approved.disability_certification_status_approved?
    assert approved.status_changes.exists?(from_status: 'awaiting_dcf', to_status: 'approved')
    assert approved.events.exists?(action: 'application_status_changed')
    assert_includes Application.with_pending_training_request, by_email.fetch('aisha.johnson@example.com')
    assert_includes Application.with_pending_evaluation_request, by_email.fetch('daniel.kim@example.com')
    assert_operator by_email.fetch('henry.davis@example.com').application_date, :<, 3.years.ago.to_date

    dependent = by_email.fetch('sofia.perez@example.com')
    assert_equal 'isabel.perez@example.com', dependent.managing_guardian.email
    assert_equal 'Parent', dependent.guardian_relationship_type
    assert_equal dependent.managing_guardian.email, dependent.user.effective_email
    assert_equal 'Legal Guardian', by_email.fetch('noah.williams@example.com').guardian_relationship_type

    expected_stages = {
      'samuel.reed@example.com' => :needs_evaluator, 'leah.patel@example.com' => :awaiting_report,
      'ethan.cole@example.com' => :needs_fulfillment, 'fatima.ali@example.com' => :awaiting_bid_award,
      'theo.martin@example.com' => :ready_to_send_po, 'nadia.bennett@example.com' => :awaiting_shipment,
      'mateo.santos@example.com' => :shipment_recorded
    }
    Application.preload_equipment_fulfillment(applications.select(&:status_approved?))
    expected_stages.each do |email, stage|
      result = by_email.fetch(email).equipment_fulfillment_stage
      assert_equal stage, result.stage, email
      assert_not_nil result.entered_at, email
    end
    assert_equal ['low_vision_blind'], by_email.fetch('ethan.cole@example.com').program_disability_groups
    assert_equal 'low_vision_blind', by_email.fetch('ethan.cole@example.com').equipment_needs.remaining.sole.disability_setup_group

    awaiting_report = by_email.fetch('leah.patel@example.com')
    assert awaiting_report.evaluations.sole.status_requested?
    assert_operator awaiting_report.events.find_by!(action: 'evaluator_assigned').created_at, :>, awaiting_report.evaluation_requested_at
    scheduled_evaluation = by_email.fetch('julian.torres@example.com').evaluations.sole
    assert scheduled_evaluation.status_scheduled?
    assert_operator scheduled_evaluation.evaluation_date, :>, Time.current
    assert Event.exists?(auditable: scheduled_evaluation, action: 'evaluation_scheduled')

    awaiting_shipment = by_email.fetch('nadia.bennett@example.com').equipment_items.sole
    assert_not_nil awaiting_shipment.purchase_order.sent_at
    assert_not_nil awaiting_shipment.shipment_wait_started_at
    shipped = by_email.fetch('mateo.santos@example.com').equipment_items.find_by!(funding_source: 'icanconnect')
    assert_operator shipped.shipped_at, :>=, shipped.purchase_order.sent_at
    assert shipped.serial_number.start_with?('DEMO-UNIT-')

    unscheduled = by_email.fetch('chloe.davis@example.com').training_sessions.sole
    scheduled = by_email.fetch('isaac.green@example.com').training_sessions.sole
    completed = by_email.fetch('amara.owens@example.com').training_sessions.sole
    assert unscheduled.status_requested?
    assert_nil unscheduled.scheduled_for
    assert scheduled.status_scheduled?
    assert_operator scheduled.scheduled_for, :>, Time.current
    assert completed.status_completed?
    assert_operator completed.completed_at, :<=, completed.report_submitted_at
    assignment = Event.find_by!(action: 'trainer_assigned', auditable: completed.application)
    scheduling = Event.find_by!(action: 'training_scheduled', auditable: completed)
    assert_operator scheduling.created_at, :>, assignment.created_at
    assert_operator completed.completed_at, :>, scheduling.created_at
    ProofReview.reviewable_proof_types.each do |type|
      receipt = approved.document_attachment_for(type).attachment
      review = approved.proof_reviews.status_approved.find_by!(proof_type: type, reviewed_blob_id: receipt.blob_id)
      assert_operator review.reviewed_at, :>, receipt.created_at
    end
  end

  test 'ICC examples include mixed device funding complete synthetic evidence and an incomplete assessment bill' do
    FeatureFlag.find_by!(name: 'vouchers_enabled').update!(enabled: false)
    applications = Seeds::DevelopmentApplications.new(admin: @admin).call
    by_email = applications.index_by { |application| application.user.email }

    %w[mateo.santos@example.com nora.ellis@example.com].each do |email|
      application = by_email.fetch(email)
      assert application.icanconnect_eligible?
      assert application.required_proofs_approved?
      assert application.disability_certification_status_approved?
      assert application.status_changes.exists?(to_status: 'approved')
      assert_equal %w[icanconnect mat], application.equipment_items.order(:funding_source).pluck(:funding_source)

      icc_item = application.equipment_items.find_by!(funding_source: 'icanconnect')
      mat_item = application.equipment_items.find_by!(funding_source: 'mat')
      assert_equal 'freedom-scientific-focus-40-blue-5th-generation-refreshable-braille-display', icc_item.product.catalog_key
      assert_equal 'apple-iphone-17', mat_item.product.catalog_key
      assert_equal BigDecimal('3595'), icc_item.unit_cost
      assert_equal BigDecimal('799'), mat_item.unit_cost
      assert_not_equal icc_item.purchase_order_id, mat_item.purchase_order_id
      [icc_item, mat_item].each do |item|
        assert_equal item.funding_source, item.purchase_order.funding_source
        assert item.purchase_order.invoice_reconciled?
        assert DocumentScan.cleared?(item.purchase_order.financial_document.blob)
        assert_operator item.delivered_on, :>, item.shipped_at
        assert_equal item.delivered_on, item.installed_on
      end
      assert Icanconnect::FilingPrep.row(icc_item).ready?
      assert Icanconnect::FilingPrep.row(icc_item.purchase_order).ready?
      assessment = Icanconnect::FilingPrep.row(application.evaluations.sole)
      assert_not assessment.ready?
      assert_includes assessment.missing, 'Actual cost missing'
    end

    nora = by_email.fetch('nora.ellis@example.com')
    session = nora.training_sessions.sole
    assert session.status_completed?
    assert_equal 'icanconnect', session.funding_source
    assert_equal BigDecimal('142.50'), session.actual_service_cost
    assert_equal nora.equipment_items.where(funding_source: 'icanconnect').ids, session.equipment_item_ids
    assert Icanconnect::FilingPrep.row(session).ready?

    rows = Icanconnect::FilingPrep.new(from: 60.days.ago.to_date, through: Date.current).rows
    assert rows.any?(&:ready?)
    assert(rows.any? { |row| !row.ready? })
    assert(rows.all? { |row| row.record.funding_source == 'icanconnect' })
    assert(rows.any? { |row| row.record == session })
    assert(rows.none? { |row| row.record == nora.equipment_items.find_by!(funding_source: 'mat') })
  end

  test 'additive ICC refresh preserves retained applications while filling the Jane examples missing groups' do
    FeatureFlag.find_by!(name: 'vouchers_enabled').update!(enabled: false)
    mateo = create(:constituent, email: 'mateo.santos@example.com')
    retained = create(:application, user: mateo)
    janes = %w[user2@example.com jane.doe@example.com].map { |email| User.find_by_email(email) }
    jane_applications = Application.where(user: janes).order(:id).map(&:attributes)
    retained_attributes = retained.attributes

    examples = Seeds::DevelopmentApplications.new(admin: @admin).call

    assert_not_includes examples.map(&:user_id), mateo.id
    assert_equal retained_attributes, retained.reload.attributes
    Application.where(user: janes).order(:id).zip(jane_applications).each do |application, previous|
      assert_equal previous.except('program_disability_groups', 'updated_at', 'lock_version'),
                   application.attributes.except('program_disability_groups', 'updated_at', 'lock_version')
      assert_equal ['deaf'], application.program_disability_groups
    end
    nora = examples.find { |application| application.user.email == 'nora.ellis@example.com' }
    assert nora.equipment_items.exists?(funding_source: 'icanconnect')
    assert nora.training_sessions.status_completed.exists?
  end

  test 'additive examples preserve existing contacts skip completed examples and suppress provider delivery' do
    retained = create(:constituent, email: 'maya.brooks@example.com', first_name: 'Retained')
    attributes = retained.attributes
    retained_application = create(:application, :draft, user: retained, program_disability_groups: [])
    retained_application_attributes = retained_application.attributes
    aisha = create(:constituent, email: 'aisha.johnson@example.com', first_name: 'Aisha', last_name: 'Johnson',
                                 hearing_disability: false, vision_disability: true, mobility_disability: true)
    aisha_application = create(:application, :draft, user: aisha, program_disability_groups: [])
    aisha_before = aisha_application.attributes
    noah = create(:constituent, email: 'noah.williams@example.com', first_name: 'Noah', last_name: 'Williams')
    noah_application = create(:application, :draft, user: noah, program_disability_groups: ['speech'])
    noah_before = noah_application.attributes
    adapter = ActiveJob::Base.queue_adapter
    delivery_method = ActionMailer::Base.delivery_method
    perform_deliveries = ActionMailer::Base.perform_deliveries
    twilio = Rails.application.config.twilio
    Postmark::ApiClient.expects(:new).never
    Twilio::REST::Client.expects(:new).never

    examples = Seeds::DevelopmentApplications.new(admin: @admin).call

    assert_equal Seeds::DevelopmentApplications::PROFILES.size - 3, examples.size
    assert_equal attributes, retained.reload.attributes
    assert_equal retained_application_attributes, retained_application.reload.attributes
    assert_equal %w[low_vision_blind mobility], aisha_application.reload.program_disability_groups
    assert_equal aisha_before.except('program_disability_groups', 'updated_at', 'lock_version'),
                 aisha_application.attributes.except('program_disability_groups', 'updated_at', 'lock_version')
    assert_equal @admin.id, aisha_application.events.find_by!(action: 'equipment_profile_updated').user_id
    assert_equal noah_before, noah_application.reload.attributes
    assert_same adapter, ActiveJob::Base.queue_adapter
    assert_equal delivery_method, ActionMailer::Base.delivery_method
    assert_equal perform_deliveries, ActionMailer::Base.perform_deliveries
    assert_same twilio, Rails.application.config.twilio
    assert_no_difference ['Application.count', 'User.count', 'Event.count', 'EquipmentItem.count', 'Evaluation.count', 'TrainingSession.count'] do
      assert_empty Seeds::DevelopmentApplications.new(admin: @admin).call
    end
  end

  test 'voucher gallery follows the configured income and fulfillment policy' do
    FeatureFlag.find_by!(name: 'vouchers_enabled').update!(enabled: true)
    applications = Seeds::DevelopmentApplications.new(admin: @admin).call

    assert applications.all?(&:voucher_fulfillment?)
    assert applications.none?(&:income_proof_required?)
    assert(applications.all? { |application| application.annual_income.nil? && application.household_size.nil? })
    assert(applications.none? { |application| application.income_proof.attached? })
    assert(applications.reject(&:status_draft?).all? { |application| application.id_proof.attached? })
    assert_equal Application.statuses.keys.sort, applications.map(&:status).uniq.sort
    applications.select(&:status_approved?).each do |application|
      assert application.required_proofs_approved?
      assert application.disability_certification_status_approved?
    end
  end
end
