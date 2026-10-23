# frozen_string_literal: true

require 'test_helper'

class SessionActivityTest < ActionDispatch::IntegrationTest
  setup do
    Current.reset
    @user = create(:constituent)
  end

  test 'real sign-in activity slides idle expiry while retaining absolute expiry' do
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      assert_redirected_to constituent_portal_dashboard_path
      session_record = @user.sessions.last
      absolute_expiry = session_record.expires_at

      travel 29.minutes
      get edit_profile_path
      assert_response :success
      assert_equal Time.current, session_record.reload.last_active_at
      assert_equal absolute_expiry, session_record.expires_at

      travel 30.minutes
      get edit_profile_path
      assert_redirected_to sign_in_path
      assert_equal 'Your session expired; please sign in again.', flash[:alert]
      assert cookies[:session_token].blank?
    end
  end

  test 'expired JSON requests return no-store 401' do
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      travel 30.minutes

      get edit_profile_path, as: :json

      assert_response :unauthorized
      assert_equal 'authentication_required', response.parsed_body.fetch('error')
      assert_includes response.headers.fetch('Cache-Control'), 'no-store'
    end
  end

  test 'public authentication status checks do not refresh activity' do
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      session_record = @user.sessions.last
      initial_activity = session_record.last_active_at

      travel 15.minutes
      get '/test/auth_status', as: :json
      assert response.parsed_body.fetch('authenticated')
      assert_equal initial_activity, session_record.reload.last_active_at

      travel 15.minutes
      get '/test/auth_status', as: :json
      assert_not response.parsed_body.fetch('authenticated')
      assert_equal initial_activity, session_record.reload.last_active_at
    end
  end

  test 'background scan polling does not extend idle expiry and recovery survives signing in again' do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new('%PDF-1.4 document'), filename: 'document.pdf')
    scan = DocumentScan.create!(blob: blob, user: @user, purpose: :proof, slot: 'income_proof', sha256: 'a' * 64)
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      session_record = @user.sessions.last
      initial_activity = session_record.last_active_at
      travel 29.minutes
      get document_scan_path(scan), as: :json
      assert_response :success
      assert_equal initial_activity, session_record.reload.last_active_at
      travel 1.minute
      get document_scan_path(scan), as: :json
      assert_response :unauthorized
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      get document_scan_path(scan), as: :json
      assert_response :success
      assert_equal scan.id, response.parsed_body.fetch('id')
    end
  end

  test 'public pages do not extend a signed-in session' do
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      session_record = @user.sessions.last
      initial_activity = session_record.last_active_at
      travel 15.minutes

      get help_path

      assert_response :success
      assert_equal initial_activity, session_record.reload.last_active_at
    end
  end

  {
    en: 'Your session expired; please sign in again.',
    es: 'Su sesión ha expirado; vuelva a iniciar sesión.'
  }.each do |locale, message|
    %i[idle absolute].each do |deadline|
      test "#{deadline} expiry preserves #{locale} through the sign-in page" do
        @user.update!(locale: locale)
        freeze_time do
          post sign_in_path, params: { email: @user.email, password: 'password1234' }
          @user.sessions.last.update!(expires_at: 5.minutes.from_now) if deadline == :absolute
          travel(deadline == :idle ? 30.minutes : 5.minutes)

          get constituent_portal_dashboard_path

          assert_redirected_to sign_in_path(locale: (:es if locale == :es))
          assert_equal message, flash[:alert]
          assert cookies[:session_token].blank?
          follow_redirect!
          assert_response :success
          assert_select '[data-testid="flash-alert"]', text: message
          assert_select '#signin-heading', text: I18n.t('sessions.title', locale: locale)
        end
      end
    end
  end

  test 'supported request locale overrides the expired session user locale' do
    @user.update!(locale: :es)
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      travel 30.minutes

      get constituent_portal_dashboard_path(locale: :en)

      assert_redirected_to sign_in_path
      assert_equal 'Your session expired; please sign in again.', flash[:alert]
    end
  end

  test 'anonymous Spanish request receives generic localized sign-in guidance' do
    get constituent_portal_dashboard_path(locale: :es)

    assert_redirected_to sign_in_path(locale: :es)
    assert_equal 'Inicie sesión para continuar.', flash[:alert]
    follow_redirect!
    assert_select '[data-testid="flash-alert"]', text: 'Inicie sesión para continuar.'
    assert_select '#signin-heading', text: 'Iniciar sesión'
  end

  test 'unsupported anonymous request locale falls back to default sign-in guidance' do
    get constituent_portal_dashboard_path(locale: 'unsupported')

    assert_redirected_to sign_in_path
    assert_equal 'Please sign in to continue', flash[:alert]
  end

  test 'unsupported request locale preserves an expired Spanish session locale' do
    @user.update!(locale: :es)
    freeze_time do
      post sign_in_path, params: { email: @user.email, password: 'password1234' }
      travel 30.minutes

      get constituent_portal_dashboard_path(locale: 'unsupported')

      assert_redirected_to sign_in_path(locale: :es)
      assert_equal 'Su sesión ha expirado; vuelva a iniciar sesión.', flash[:alert]
    end
  end
end
