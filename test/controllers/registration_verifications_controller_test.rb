# frozen_string_literal: true

require 'test_helper'

class RegistrationVerificationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ensure_system_audit_actor!
    load_seeded_email_templates('application_notifications_registration_confirmation')
    @verification = RegistrationVerification.create!(email: 'verified-registration@example.test', locale: 'en',
                                                     expires_at: 20.minutes.from_now)
    @token = @verification.proof_token
    @attributes = { first_name: 'New', last_name: 'Registrant', password: 'password1234',
                    password_confirmation: 'password1234', date_of_birth: '01/15/1990',
                    timezone: 'Eastern Time (US & Canada)', locale: 'en', communication_preference: 'email' }
  end

  test 'get shows password only after proof and never consumes the request' do
    assert_no_difference ['User.count', 'Session.count'] do
      get edit_registration_verification_path(token: @token)
    end

    assert_response :success
    assert_nil @verification.reload.consumed_at
    assert_select 'input#user_password[type=password]'
    assert_select 'input[name="user[email]"]', count: 0
    assert_select 'input[name="user[phone]"]', count: 0
    assert_equal 'no-store', response.headers['Cache-Control']
    assert_equal 'no-referrer', response.headers['Referrer-Policy']
  end

  test 'missing tampered wrong purpose expired and spent proofs create no authority' do
    tokens = ['', "#{@token}tampered", @verification.signed_id(purpose: :contact_email),
              @verification.signed_id(purpose: RegistrationVerification::TOKEN_PURPOSE, expires_at: 1.second.ago)]
    tokens.each do |token|
      assert_no_difference ['User.count', 'Session.count'] do
        patch registration_verification_path(token: token.presence || 'missing'), params: { user: @attributes }
      end
      assert_redirected_to sign_up_path(locale: 'en')
    end
    @verification.update!(consumed_at: Time.current)
    assert_no_difference ['User.count', 'Session.count'] do
      patch registration_verification_path(token: @token), params: { user: @attributes }
    end
    assert_redirected_to sign_up_path(locale: 'en')
  end

  test 'completion takes email from proof ignores a replacement email and phone and consumes once' do
    other = create(:constituent)
    original_digest = other.password_digest
    injected = @attributes.merge(email: other.email, phone: other.phone, phone_type: 'text', type: 'Users::Administrator')
    assert_difference ['User.count', 'Session.count'], 1 do
      patch registration_verification_path(token: @token), params: { user: injected }
    end

    assert_redirected_to welcome_path
    user = @verification.reload.created_user
    assert_equal 'Users::Constituent', user.type
    assert_equal @verification.email, user.email
    assert_nil user.phone
    assert user.email_verified?
    assert user.authenticate(@attributes[:password])
    assert @verification.consumed_at
    assert_equal original_digest, other.reload.password_digest
    assert_equal user, Event.find_by!(action: 'registration_email_verified', auditable: user).user
    assert_no_difference ['User.count', 'Session.count', 'DuplicateReviewCase.count'] do
      patch registration_verification_path(token: @token), params: { user: injected }
    end
  end

  test 'existing account at get or final post is not authenticated or overwritten' do
    get edit_registration_verification_path(token: @token)
    assert_response :success
    user = create(:constituent, email: @verification.email)
    digest = user.password_digest
    assert_no_difference ['User.count', 'Session.count', 'DuplicateReviewCase.count'] do
      patch registration_verification_path(token: @token), params: { user: @attributes.merge(password: 'different-secret') }
    end

    assert_redirected_to sign_in_path(locale: 'en')
    assert_nil cookies[:session_token]
    assert_equal digest, user.reload.password_digest
    next_proof = RegistrationVerification.create!(email: user.email, locale: 'en', expires_at: 20.minutes.from_now)
    get edit_registration_verification_path(token: next_proof.proof_token)
    assert_redirected_to sign_in_path(locale: 'en')
    assert_nil next_proof.reload.consumed_at
  end

  test 'invalid profile stays editable and the same unexpired link succeeds after correction' do
    assert_no_difference ['User.count', 'Session.count'] do
      patch registration_verification_path(token: @token), params: { user: @attributes.merge(last_name: '', password: 'short') }
    end
    assert_response :unprocessable_content
    assert_nil @verification.reload.consumed_at
    assert_select 'input[name="user[first_name]"][value=New]'
    assert_select '#user_password-error'

    assert_difference('User.count') do
      patch registration_verification_path(token: @token), params: { user: @attributes }
    end
    assert_redirected_to welcome_path
  end

  test 'expiry is checked again at final post after a valid get' do
    get edit_registration_verification_path(token: @token)
    travel 21.minutes do
      assert_no_difference ['User.count', 'Session.count'] do
        patch registration_verification_path(token: @token), params: { user: @attributes }
      end
      assert_redirected_to sign_up_path(locale: 'en')
    end
  end

  test 'soft duplicate creates one required review case atomically with the new account' do
    candidate = create(:constituent, first_name: @attributes[:first_name], last_name: @attributes[:last_name],
                                     date_of_birth: Date.new(1990, 1, 15))
    assert_difference ['User.count', 'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'], 1 do
      patch registration_verification_path(token: @token), params: { user: @attributes }
    end

    review = DuplicateReviewCase.find_by!(subject_user: @verification.reload.created_user)
    assert_equal 'registration_soft_match', review.source
    assert_equal [candidate.id], review.duplicate_review_case_candidates.pluck(:candidate_user_id)
    assert review.subject_user.needs_duplicate_review?
  end

  test 'duplicate read failure cannot become an unchecked account' do
    DuplicateDetectionService.any_instance.stubs(:call).raises(ActiveRecord::StatementInvalid, 'private query failure')
    assert_no_difference ['User.count', 'Session.count', 'DuplicateReviewCase.count'] do
      patch registration_verification_path(token: @token), params: { user: @attributes }
    end
    assert_nil @verification.reload.consumed_at
    assert_redirected_to sign_in_path(locale: 'en')
    assert_equal I18n.t('registration_verification.completion_failed'), flash[:alert]
  end

  test 'exact and soft query failures do not create unchecked accounts' do
    original_lookup = User.method(:find_by_email)
    lookup = lambda do |email|
      raise ActiveRecord::StatementInvalid, 'lookup unavailable' if email == @verification.email

      original_lookup.call(email)
    end
    User.stub(:find_by_email, lookup) do
      assert_no_difference ['User.count', 'Session.count'] do
        patch registration_verification_path(token: @token), params: { user: @attributes }
      end
    end
    assert_nil @verification.reload.consumed_at

    Users::Constituent.stub(:find_duplicates, ->(*) { raise ActiveRecord::StatementInvalid, 'soft lookup unavailable' }) do
      assert_no_difference ['User.count', 'Session.count'] do
        patch registration_verification_path(token: @token), params: { user: @attributes }
      end
    end
    assert_nil @verification.reload.consumed_at
  end

  test 'required security audit failure rolls back creation and leaves proof usable' do
    original_log = AuditEventService.method(:log)
    writer = lambda do |**arguments|
      raise ActiveRecord::StatementInvalid, 'audit unavailable' if arguments[:action] == 'registration_email_verified'

      original_log.call(**arguments)
    end
    AuditEventService.stub(:log, writer) do
      assert_no_difference ['User.count', 'Session.count'] do
        patch registration_verification_path(token: @token), params: { user: @attributes }
      end
    end
    assert_nil @verification.reload.consumed_at
    assert_nil @verification.created_user_id
  end

  test 'required review failure rolls back account and proof consumption' do
    create(:constituent, first_name: @attributes[:first_name], last_name: @attributes[:last_name],
                         date_of_birth: Date.new(1990, 1, 15))
    PublicAuditActor.stubs(:system_audit_actor).returns(nil)
    assert_no_difference ['User.count', 'Session.count', 'DuplicateReviewCase.count'] do
      patch registration_verification_path(token: @token), params: { user: @attributes }
    end
    assert_nil @verification.reload.consumed_at
    assert_nil @verification.created_user_id
  end

  test 'completion follows the profile language selected after email proof' do
    patch registration_verification_path(token: @token), params: { user: @attributes.merge(locale: 'es') }

    assert_redirected_to welcome_path
    assert_equal 'es', @verification.reload.created_user.locale
    assert_equal I18n.t('portal_self_service.registrations.account_created', locale: :es), flash[:notice]
  end

  test 'committed account remains created when canonical session issuance fails' do
    RegistrationVerificationsController.any_instance.stubs(:_create_and_set_session_cookie).returns(nil)
    assert_difference('User.count') do
      assert_no_difference('Session.count') do
        patch registration_verification_path(token: @token), params: { user: @attributes }
      end
    end
    assert_redirected_to sign_in_path(locale: 'en')
    assert @verification.reload.created_user_id
    assert_equal I18n.t('registration_verification.completed_sign_in'), flash[:notice]
  end
end
