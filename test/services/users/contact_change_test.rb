# frozen_string_literal: true

require 'test_helper'

module Users
  class ContactChangeTest < ActiveSupport::TestCase
    setup do
      Current.reset
      @user = create(:constituent)
      @old_email = @user.email
      @old_phone = @user.phone
      @new_email = "contact-owner-#{SecureRandom.hex(5)}@example.com"
      @record, @token = fresh_session(@user)
      @writer = writer
      Current.user = @user
    end

    test 'proof rows encrypt contact values and separate old and new address purposes' do
      change = request_email
      assert_equal @new_email, change.reload.proposed_value
      assert_not_equal @new_email, change.proposed_value_before_type_cast
      assert_not_includes change.proposed_value_before_type_cast, @new_email
      new_token = change.proof_token('new_email')
      assert_equal change, ContactChangeRequest.find_for_proof(new_token, 'new_email')
      assert_nil ContactChangeRequest.find_for_proof(new_token, 'old_email')
      assert_nil ContactChangeRequest.find_for_proof(new_token, 'registration')
      assert_raises(ArgumentError) { change.proof_token('registration') }
      change.update!(canceled_at: Time.current)
      assert_nil ContactChangeRequest.find_for_proof(new_token, 'new_email')
    end

    test 'a signed link cannot extend the stored request deadline' do
      change = request_email
      token = change.proof_token('new_email')
      travel_to(change.expires_at + 1.second) do
        assert_nil ContactChangeRequest.find_for_proof(token, 'new_email')
        assert_not change.pending?
      end
      assert_equal @old_email, @user.reload.email
    end

    test 'another authority mutation invalidates proof even after fresh authentication is renewed' do
      change = request_email
      confirm_both(change)
      User.transaction do
        locked = User.lock_for_merge_integrity!(@user).fetch(@user.id)
        locked.advance_security_version!
        @record.rotate_after_authentication!(user: locked)
      end
      @token = @record.session_token
      assert_raises(ContactChangeRequest::Refused) { writer.complete!(change) }
      assert_equal @old_email, @user.reload.email
      assert_nil change.reload.completed_at
    end

    test 'the original loaded bearer cannot inherit freshness after token rotation' do
      change = request_email
      confirm_both(change)
      stale_record = Session.find(@record.id)
      old_token = @token
      User.transaction do
        locked = User.lock_for_merge_integrity!(@user).fetch(@user.id)
        @record.rotate_after_authentication!(user: locked)
      end
      stale_writer = ContactChange.new(user: @user, actor: @user, session: stale_record, token: old_token)
      assert_raises(Session::AuthenticationRequired) { stale_writer.complete!(change) }
      assert_equal @old_email, @user.reload.email
      assert_nil change.reload.completed_at
    end

    test 'failure while persisting completion notices rolls back contact version and session state' do
      change = request_email
      confirm_both(change)
      old_version = @user.security_version
      ContactChangeRequest.any_instance.expects(:prepare_completed_deliveries!).raises(ActiveRecord::RecordNotSaved)
      assert_raises(ActiveRecord::RecordNotSaved) { @writer.complete!(change) }
      assert_equal @old_email, @user.reload.email
      assert_equal old_version, @user.security_version
      assert Session.exists?(@record.id)
      assert_nil change.reload.completed_at
      assert_empty change.delivery_states.slice('old_completed', 'new_completed')
      assert_not Event.exists?(action: 'account_contact_change_completed', auditable: @user)
    end

    test 'resend retains the deadline and refuses a revoked session before renewing any delivery intent' do
      change = request_email
      deadline = change.expires_at
      previous_contexts = change.delivery_contexts
      @writer.resend!(change)
      assert_equal deadline, change.reload.expires_at
      assert_not_equal previous_contexts, change.delivery_contexts

      current_contexts = change.delivery_contexts
      Session.find(@record.id).destroy!
      assert_raises(Session::AuthenticationRequired) { @writer.resend!(change) }
      assert_equal current_contexts, change.reload.delivery_contexts
      assert_equal deadline, change.expires_at
      assert_equal @old_email, @user.reload.email
    end

    test 'resend cannot renew a canceled request even with the original fresh session' do
      change = request_email
      original_contexts = change.delivery_contexts
      ContactChangeRequest.find(change.id).update!(canceled_at: Time.current)
      assert_raises(ContactChangeRequest::Refused) { @writer.resend!(change) }
      assert_equal original_contexts, change.reload.delivery_contexts
      assert change.canceled_at
    end

    test 'failed ownership verification and an expired SMS challenge never promote a phone' do
      change = @writer.request!(kind: 'phone', proposed_value: '4105550171', phone_type: 'text')
      TwilioVerifyService.expects(:send_verification).returns(success: true, verification_sid: 'VE-phone-change', code_expires_at: 10.minutes.from_now.to_i)
      @writer.send_sms!(change)
      TwilioVerifyService.expects(:check_verification).returns(success: true, status: 'pending')
      assert_raises(ContactChangeRequest::Refused) { @writer.confirm_sms!(change, code: '000000') }
      assert_nil change.reload.new_confirmed_at
      change.update!(sms_expires_at: 1.second.ago)
      TwilioVerifyService.expects(:check_verification).returns(success: true, status: 'approved')
      assert_raises(ContactChangeRequest::Refused) { @writer.confirm_sms!(change, code: '123456') }
      assert_nil change.reload.new_confirmed_at
      assert_equal @old_phone, @user.reload.phone
    end

    test 'an authority change during an SMS provider check makes its success unusable' do
      change = @writer.request!(kind: 'phone', proposed_value: '4105550172', phone_type: 'text')
      change.update!(sms_verification_sid: 'VE-phone-change', sms_expires_at: 10.minutes.from_now)
      TwilioVerifyService.expects(:check_verification).with do |_phone, _code, **_options|
        User.transaction { User.lock_for_merge_integrity!(@user).fetch(@user.id).advance_security_version! }
        true
      end.returns(success: true, status: 'approved')
      assert_raises(Session::AuthenticationRequired) { @writer.confirm_sms!(change, code: '123456') }
      assert_nil change.reload.new_confirmed_at
      assert_equal @old_phone, @user.reload.phone
    end

    test 'staff assisted non SMS update records proof and revokes the target sessions' do
      admin = create(:admin)
      record, token = fresh_session(admin)
      Current.user = admin
      old_version = @user.security_version
      rows = ContactChange.new(user: @user, actor: admin, session: record, token: token)
                          .staff_update!({ 'phone' => '4105550173', 'phone_type' => 'voice' }, verification: staff_proof)
      assert_equal PhoneNumber.normalize('4105550173'), @user.reload.phone
      assert_equal 'voice', @user.phone_type
      assert_equal old_version + 1, @user.security_version
      assert_empty @user.sessions
      assert Session.exists?(record.id)
      assert rows.sole.reload.completed_at
      metadata = Event.find_by!(action: 'account_contact_change_completed', auditable: @user).metadata
      assert_equal 'CASE-456', metadata.dig('verification', 'reference')
      assert_equal true, metadata.dig('verification', 'identity_verified')
      assert_equal true, metadata.dig('verification', 'new_contact_association_verified')
      assert_not_includes metadata.to_json, '4105550173'
    end

    test 'staff proof refusal and invalid contact roll back unrelated profile edits' do
      admin = create(:admin)
      record, token = fresh_session(admin)
      Current.user = admin
      staff_writer = ContactChange.new(user: @user, actor: admin, session: record, token: token)
      first_name = @user.first_name
      attributes = { 'first_name' => 'Updated', 'phone' => '4105550174', 'phone_type' => 'voice' }
      assert_raises(ContactChangeRequest::Refused) do
        staff_writer.staff_update!(attributes, verification: staff_proof.merge(association_verified: false))
      end
      assert_equal @old_phone, @user.reload.phone
      assert_equal first_name, @user.first_name

      assert_raises(ActiveRecord::RecordInvalid) do
        staff_writer.staff_update!(attributes.merge('phone' => 'invalid'), verification: staff_proof)
      end
      assert_equal @old_phone, @user.reload.phone
      assert_equal first_name, @user.first_name
      assert_empty ContactChangeRequest.where(user_id: @user.id)
    end

    test 'ordinary users cannot use staff override for another owner' do
      other = create(:constituent)
      record, token = fresh_session(other)
      assert_raises(ContactChangeRequest::Refused) do
        ContactChange.new(user: @user, actor: other, session: record, token: token)
                     .staff_update!({ 'email' => @new_email }, verification: staff_proof)
      end
      assert_equal @old_email, @user.reload.email
    end

    private

    def fresh_session(user)
      record = Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'Contact service boundary',
                               reauthenticated_at: Time.current, reauthenticated_security_version: user.security_version)
      [record, record.session_token]
    end

    def writer
      ContactChange.new(user: @user, actor: @user, session: @record, token: @token)
    end

    def request_email
      @writer.request!(kind: 'email', proposed_value: @new_email)
    end

    def confirm_both(change)
      change.update!(old_confirmed_at: Time.current, new_confirmed_at: Time.current)
    end

    def staff_proof
      { method: 'Approved non-SMS check', reference: 'CASE-456', identity_verified: true, association_verified: true }
    end
  end
end
