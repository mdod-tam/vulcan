# frozen_string_literal: true

require 'test_helper'

class ApplicationStatusChangeLifecycleTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin)
    @application = create(:application, :draft)
  end

  test 'lifecycle includes status transitions from transition_status!' do
    @application.transition_status!(:in_progress, actor: @admin, metadata: { trigger: 'test' })

    change = ApplicationStatusChange.lifecycle.find_by(application: @application)
    assert_not_nil change
  end

  test 'lifecycle includes legacy nil change_type rows for application status keys' do
    ApplicationStatusChange.create!(
      application: @application,
      from_status: 'draft',
      to_status: 'in_progress',
      change_type: nil,
      changed_at: Time.current,
      user: @admin,
      metadata: { trigger: 'legacy' }
    )

    assert_equal 1, ApplicationStatusChange.lifecycle.where(application: @application, to_status: 'in_progress').count
  end

  test 'lifecycle excludes medical certification rows by change_type' do
    ApplicationStatusChange.create!(
      application: @application,
      from_status: 'in_progress',
      to_status: 'approved',
      change_type: :medical_certification,
      changed_at: Time.current,
      user: @admin
    )

    assert_empty ApplicationStatusChange.lifecycle.where(application: @application)
  end

  test 'lifecycle excludes metadata-only medical certification rows' do
    ApplicationStatusChange.create!(
      application: @application,
      from_status: 'in_progress',
      to_status: 'approved',
      change_type: nil,
      changed_at: Time.current,
      user: @admin,
      metadata: { 'change_type' => 'medical_certification' }
    )

    assert_empty ApplicationStatusChange.lifecycle.where(application: @application, to_status: 'approved')
  end

  test 'lifecycle counts approved only for status and legacy lifecycle rows' do
    @application.transition_status!(:in_progress, actor: @admin, metadata: { trigger: 'test' })
    @application.transition_status!(:approved, actor: @admin, metadata: { trigger: 'test' })

    ApplicationStatusChange.create!(
      application: @application,
      from_status: 'approved',
      to_status: 'approved',
      change_type: :medical_certification,
      changed_at: Time.current,
      user: @admin
    )

    assert_equal 1, ApplicationStatusChange.lifecycle.where(application: @application, to_status: 'approved').count
  end
end
