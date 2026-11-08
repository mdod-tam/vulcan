# frozen_string_literal: true

require 'test_helper'

class RecoveryRequestTest < ActiveSupport::TestCase
  setup do
    @user = FactoryBot.create(:user, email: "recovery-user-#{SecureRandom.hex(4)}@example.com")
    @admin = FactoryBot.create(:admin, email: "recovery-admin-#{SecureRandom.hex(4)}@example.com")
  end

  test 'should create valid recovery request' do
    request = RecoveryRequest.new(
      user: @user,
      status: 'pending',
      details: 'Lost my security key',
      ip_address: '127.0.0.1',
      user_agent: 'Test Agent'
    )

    assert request.valid?
    assert request.save
  end

  test 'should require user association' do
    request = RecoveryRequest.new(
      status: 'pending',
      details: 'Lost my security key'
    )

    assert_not request.valid?
    assert_includes request.errors.full_messages, 'User must exist'
  end

  test 'should have pending status by default' do
    request = RecoveryRequest.new(user: @user)
    assert_equal 'pending', request.status
  end

  test 'database enforces one pending recovery request per user' do
    FactoryBot.create(:recovery_request, user: @user, status: 'pending')

    assert_raises(ActiveRecord::RecordNotUnique) do
      FactoryBot.create(:recovery_request, user: @user, status: 'pending')
    end
  end

  test 'database allows a new pending recovery request after prior request is resolved' do
    FactoryBot.create(:recovery_request, :approved, user: @user)

    request = FactoryBot.build(:recovery_request, user: @user, status: 'pending')

    assert request.save
  end

  test 'approval requires an explicit successful verification and nonsecret reference' do
    request = FactoryBot.build(:recovery_request, user: @user)
    assert_not request.valid?(:approval)
    assert request.errors.added?(:identity_check_completed, :accepted)

    request.assign_attributes(verification_method: 'staff_assisted_non_sms', verification_result: 'verified',
                              verification_reference: 'CASE-123', identity_check_completed: '1')
    assert request.valid?(:approval)

    request.identity_check_completed = '0'
    assert_not request.valid?(:approval)
    request.identity_check_completed = '1'
    request.verification_result = 'failed'
    assert_not request.valid?(:approval)
    request.verification_result = 'verified'
    request.verification_reference = 'x' * 201
    assert_not request.valid?(:approval)
  end
end
