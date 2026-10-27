# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/seeds/development_applications'

class DevelopmentApplicationsTest < ActiveSupport::TestCase
  setup do
    Rails.env.stubs(:development?).returns(true)
    @admin = User.find_by_email('admin@example.com')
    # Exercise the submission rules that run in development too.
    @original_proof_validation = ENV.fetch('REQUIRE_PROOF_VALIDATIONS', nil)
    ENV['REQUIRE_PROOF_VALIDATIONS'] = 'true'
  end

  teardown do
    ENV['REQUIRE_PROOF_VALIDATIONS'] = @original_proof_validation
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
    assert rejected.id_proof_status_rejected?
    assert_equal 'The photo ID is unreadable. Please upload a clearer copy.', rejected.proof_reviews.find_by!(proof_type: :id).rejection_reason

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
  end

  test 'voucher gallery follows the configured income and fulfillment policy' do
    FeatureFlag.find_by!(name: 'vouchers_enabled').update!(enabled: true)
    applications = Seeds::DevelopmentApplications.new(admin: @admin).call

    assert applications.all?(&:voucher_fulfillment?)
    assert applications.none?(&:income_proof_required?)
    assert(applications.all? { |application| application.annual_income.nil? && application.household_size.nil? })
    assert(applications.none? { |application| application.income_proof.attached? })
    assert_equal Application.statuses.keys.sort, applications.map(&:status).uniq.sort
    applications.select(&:status_approved?).each do |application|
      assert application.required_proofs_approved?
      assert application.disability_certification_status_approved?
    end
  end
end
