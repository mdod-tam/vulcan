# frozen_string_literal: true

require 'test_helper'

class ApplicationBlockingScopeTest < ActiveSupport::TestCase
  setup do
    @original_skip = Application.skip_wait_period_validation
    Application.skip_wait_period_validation = false
    @constituent = create(:constituent)
  end

  teardown do
    Application.skip_wait_period_validation = @original_skip
  end

  test 'blocking_new_submission excludes archived and rejected' do
    archived_app = create(:application, :archived, user: @constituent)
    assert_not Application.where(user_id: @constituent.id).blocking_new_submission.exists?,
               'archived application should not block new submission'

    archived_app.destroy!
    create(:application, :rejected, user: @constituent)
    assert_not Application.where(user_id: @constituent.id).blocking_new_submission.exists?,
               'rejected application should not block new submission'
  end

  test 'blocking_new_submission includes in_progress applications' do
    create(:application, :in_progress, user: @constituent)
    assert Application.where(user_id: @constituent.id).blocking_new_submission.exists?,
           'in_progress application should block new submission'
  end

  test 'blocking_new_submission includes draft applications' do
    create(:application, :draft, user: @constituent)
    assert Application.where(user_id: @constituent.id).blocking_new_submission.exists?,
           'draft application should block new submission'
  end

  test 'blocking_new_submission includes approved applications' do
    create(:application, :approved, user: @constituent)
    assert Application.where(user_id: @constituent.id).blocking_new_submission.exists?,
           'approved (not yet archived) application should block new submission'
  end

  test 'rejected app past waiting period allows new submission' do
    create(:application, :rejected, user: @constituent, application_date: 4.years.ago)
    assert_not Application.where(user_id: @constituent.id).blocking_new_submission.exists?

    new_app = Application.new(
      user: @constituent,
      status: :in_progress,
      application_date: Date.current,
      maryland_resident: true,
      self_certify_disability: true,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '555-111-2222',
      medical_provider_email: 'test@test.com',
      household_size: 1,
      annual_income: 10_000
    )
    new_app.valid?(:create)
    assert_not new_app.errors[:base].any? { |e| e.include?('wait') },
               'should not have waiting period error for old rejected app'
  end

  test 'rejected app within waiting period blocks via model validation' do
    create(:application, :rejected, user: @constituent, application_date: 1.year.ago)

    new_app = Application.new(
      user: @constituent,
      status: :in_progress,
      application_date: Date.current,
      maryland_resident: true,
      self_certify_disability: true,
      medical_provider_name: 'Dr. Test',
      medical_provider_phone: '555-111-2222',
      medical_provider_email: 'test@test.com',
      household_size: 1,
      annual_income: 10_000
    )
    new_app.valid?(:create)
    assert new_app.errors[:base].any? { |e| e.include?('wait') },
           'should have waiting period error for recent rejected app'
  end

  test 'archived app past waiting period allows new submission' do
    create(:application, :archived, user: @constituent, application_date: 4.years.ago)
    assert_not Application.where(user_id: @constituent.id).blocking_new_submission.exists?
  end
end
