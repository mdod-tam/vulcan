# frozen_string_literal: true

require 'test_helper'

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    load_seeded_email_templates('registration_email_verification')
    clear_enqueued_jobs
  end

  test 'initiation asks for email without accepting a password or phone' do
    get sign_up_path

    assert_response :success
    assert_select 'input[name="user[email]"][type=email]'
    assert_select 'input[type=password]', count: 0
    assert_select 'input[name="user[phone]"]', count: 0
    assert_equal 'no-store', response.headers['Cache-Control']
  end

  test 'known unknown and normalized email requests have the same public result and no account authority' do
    known = create(:constituent)
    admin = create(:admin)
    addresses = [known.email, admin.email, "  #{known.email.upcase}  ", 'unregistered@example.test']
    public_results = addresses.map do |email|
      assert_no_difference ['User.count', 'Session.count', 'DuplicateReviewCase.count'] do
        assert_difference('RegistrationVerification.count') do
          post sign_up_path, params: { user: { email: email, locale: 'en' } }
        end
      end
      assert_nil cookies[:session_token]
      [response.status, response.location, flash[:notice]]
    end

    assert_equal 1, public_results.uniq.size
    assert_equal I18n.t('registration_verification.check_email'), flash[:notice]
    assert_equal addresses.map { |email| User.normalize_email(email) }, RegistrationVerification.order(:id).last(4).map(&:email)
  end

  test 'legacy full form cannot create an account or preserve a preselected password' do
    assert_no_difference ['User.count', 'Session.count'] do
      post sign_up_path, params: { user: { email: 'legacy@example.test', password: 'attacker-password',
                                           password_confirmation: 'attacker-password', first_name: 'Injected',
                                           phone: '4105550198', locale: 'en' } }
    end

    proof = RegistrationVerification.order(:id).last
    assert_equal 'legacy@example.test', proof.email
    assert_not proof.has_attribute?(:password_digest)
    assert_redirected_to sign_up_path(locale: 'en', check_email: true)
  end

  test 'queued verification arguments contain only a request reference and no raw credentials' do
    post sign_up_path, params: { user: { email: 'private-job@example.test', locale: 'en', password: 'unverified-secret' } }

    payload = enqueued_jobs.find { |job| job[:args].first == 'RegistrationMailer' }.fetch(:args).to_json
    assert_includes payload, 'RegistrationVerification'
    assert_not_includes payload, 'private-job@example.test'
    assert_not_includes payload, 'unverified-secret'
    assert_not_includes payload, RegistrationVerification.order(:id).last.proof_token
  end

  test 'syntax errors preserve the entered email without consulting accounts' do
    User.expects(:find_by_email).never
    assert_no_difference ['User.count', 'RegistrationVerification.count', 'AuthRateLimitCounter.count'] do
      post sign_up_path, params: { user: { email: 'invalid', locale: 'en' } }
    end

    assert_response :unprocessable_content
    assert_select 'input[name="user[email]"][value=invalid]'
    assert_select '[role=alert]', text: I18n.t('registration_verification.invalid_email')
  end

  test 'initiation performs no account lookup even for a valid address' do
    User.expects(:find_by_email).never
    User.expects(:find_by_phone).never
    post sign_up_path, params: { user: { email: 'no-lookup@example.test', locale: 'es' } }

    assert_redirected_to sign_up_path(locale: 'es', check_email: true)
    assert_equal I18n.t('registration_verification.check_email', locale: :es), flash[:notice]
    assert_equal 'es', RegistrationVerification.order(:id).last.locale
  end

  test 'oversized email is rejected before issuance or browser-session storage' do
    EmailDelivery.expects(:issuance).never
    assert_no_difference ['User.count', 'RegistrationVerification.count', 'AuthRateLimitCounter.count'] do
      post sign_up_path, params: { user: { email: "#{'a' * 5000}@example.test", locale: 'en' } }
    end

    assert_response :unprocessable_content
    assert_select '[role=alert]', text: I18n.t('registration_verification.invalid_email')
  end

  test 'synthetic destinations cannot issue registration proof or query accounts' do
    User.expects(:find_by_email).never
    User.expects(:find_by_phone).never
    EmailDelivery.expects(:issuance).never
    RegistrationMailer.expects(:with).never

    assert_no_difference ['User.count', 'Session.count', 'RegistrationVerification.count', 'AuthRateLimitCounter.count'] do
      post sign_up_path, params: { user: { email: ' DEPENDENT@SYSTEM.MATVULCAN.LOCAL ', locale: 'en' } }
    end

    assert_response :unprocessable_content
    assert_select '[role=alert]', text: I18n.t('registration_verification.invalid_email')
  end

  test 'shared ip budget permits thirty recipients and blocks the next issuance neutrally' do
    30.times do |index|
      assert_difference('RegistrationVerification.count') do
        post sign_up_path, params: { user: { email: "budget#{index}@example.test", locale: 'en' } }
      end
    end
    expected = [response.status, response.location, flash[:notice]]

    assert_no_difference ['RegistrationVerification.count', 'User.count', 'Session.count'] do
      post sign_up_path, params: { user: { email: 'beyond-budget@example.test', locale: 'en' } }
    end
    assert_equal expected, [response.status, response.location, flash[:notice]]
  end

  test 'waiting page supports reload resend and correction without putting the address in the url or flash' do
    email = 'correctable@example.test'
    post sign_up_path, params: { user: { email: email, locale: 'es' } }
    assert_not_includes response.location, email
    assert_not_includes flash.to_hash.to_json, email
    follow_redirect!
    assert_select 'h1', text: I18n.t('registration_verification.check_email_title', locale: :es)
    assert_select 'input[name="user[email]"][type=hidden][value=?]', email
    assert_select 'input[type=submit][value=?]', I18n.t('registration_verification.resend', locale: :es)
    assert_select 'a[href=?]', new_password_path(locale: 'es')

    get sign_up_path(locale: 'es', check_email: true)
    assert_select 'input[name="user[email]"][type=hidden][value=?]', email
    assert_difference('RegistrationVerification.count') do
      post sign_up_path, params: { user: { email: email, locale: 'es' } }
    end
    get sign_up_path(locale: 'es')
    assert_select 'input[name="user[email]"][type=email][value=?]', email
    post sign_up_path, params: { user: { email: 'corrected@example.test', locale: 'es' } }
    follow_redirect!
    assert_select 'input[name="user[email]"][type=hidden][value="corrected@example.test"]'
  end

  test 'new issuance gives time for delayed email and profile entry without extending an issued deadline' do
    freeze_time do
      post sign_up_path, params: { user: { email: 'longer-window@example.test', locale: 'en' } }
      proof = RegistrationVerification.order(:id).last
      token = proof.proof_token
      assert_equal 1.hour.from_now, proof.expires_at
      travel 35.minutes
      assert_equal proof, RegistrationVerification.resolve(token)
      get edit_registration_verification_path(token: token)
      assert_response :success
      travel 26.minutes
      assert_nil RegistrationVerification.resolve(token)
    end
  end

  test 'normalized recipient cap spans ips and does not revoke delivered proofs' do
    3.times do |index|
      post sign_up_path, params: { user: { email: 'recipient@example.test', locale: 'en' } },
                         headers: { 'REMOTE_ADDR' => "203.0.113.#{index + 1}" }
    end
    first_proof = RegistrationVerification.order(:id).first
    token = first_proof.proof_token

    assert_no_difference('RegistrationVerification.count') do
      post sign_up_path, params: { user: { email: ' RECIPIENT@EXAMPLE.TEST ', locale: 'en' } },
                         headers: { 'REMOTE_ADDR' => '203.0.113.99' }
    end
    assert_equal first_proof, RegistrationVerification.resolve(token)
  end

  test 'unavailable budget or delivery configuration preserves the neutral response' do
    AuthRateLimitCounter.stub(:reserve!, ->(**) { raise ActiveRecord::ConnectionNotEstablished }) do
      assert_no_difference ['User.count', 'Session.count', 'RegistrationVerification.count'] do
        post sign_up_path, params: { user: { email: 'unavailable@example.test', locale: 'en' } }
      end
    end
    expected = [response.status, response.location, flash[:notice]]
    EmailTemplate.where(name: 'registration_email_verification').delete_all
    assert_no_difference ['User.count', 'Session.count'] do
      assert_difference('RegistrationVerification.count') do
        post sign_up_path, params: { user: { email: 'missing-template@example.test', locale: 'en' } }
      end
    end
    assert_equal expected, [response.status, response.location, flash[:notice]]
    assert_equal 'queued', RegistrationVerification.order(:id).last.delivery_status
  end
end
