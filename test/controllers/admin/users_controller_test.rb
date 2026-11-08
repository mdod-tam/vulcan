# frozen_string_literal: true

require 'test_helper'

module Admin
  class UsersControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test @admin
    end

    test 'the summary frame reuses ordered application and audit date loading' do
      user = create(:constituent, :with_disabilities)
      application = create(:application, :completed, :in_progress, user: user, application_date: Date.current)
      application.approve!(user: @admin)
      get admin_user_path(user), headers: { 'Turbo-Frame' => 'user-application-summary' }
      assert_response :success
      assert_select 'turbo-frame#user-application-summary' do
        assert_select 'h2', text: "#{user.first_name}'s Applications"
        assert_select 'div', text: /Application approved on/
        assert_select "button[data-application-id='#{application.id}']"
      end
    end

    test 'application status and voucher summary queries stay bounded as dependents grow' do
      guardian = create(:constituent, :with_disabilities)
      add_dependent = lambda do
        dependent = create(:constituent, :with_disabilities)
        create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
        application = create(:application, :approved, user: dependent, managing_guardian: guardian)
        create(:voucher, application: application)
      end
      2.times { add_dependent.call }
      counts = []
      2.times do |round|
        queries = []
        observer = lambda do |_name, _start, _finish, _id, payload|
          sql = payload[:sql]
          queries << sql if !payload[:cached] && sql.start_with?('SELECT') && sql.match?(/FROM "(?:applications|application_status_changes|vouchers)"/)
        end
        ActiveSupport::Notifications.subscribed(observer, 'sql.active_record') { get admin_user_path(guardian) }
        assert_response :success
        counts << queries.length
        4.times { add_dependent.call } if round.zero?
      end
      assert_equal counts.first, counts.last
    end

    test 'invalid role feedback stays available to the admin without logging the submitted value' do
      user = create(:constituent)
      original_type = user.type
      submitted_role = 'private-role-sentinel person@example.test token=private-role-token'
      log = StringIO.new

      assert_no_difference ['User.count', 'RoleCapability.count', 'Event.count'] do
        Rails.stub(:logger, ActiveSupport::Logger.new(log)) do
          patch update_role_admin_user_path(user), params: { role: submitted_role }, headers: { 'Accept' => Mime[:turbo_stream].to_s }
        end
      end

      assert_response :unprocessable_content
      assert_includes response.body, ERB::Util.html_escape("Invalid role specified: '#{submitted_role}'. Please select a valid role.")
      assert_equal original_type, user.reload.type
      %w[private-role-sentinel person@example.test private-role-token].each do |value|
        assert_not_includes log.string, value
      end
    end

    test 'show offers deactivation that preserves history instead of deletion' do
      user = create(:constituent)

      get admin_user_path(user), headers: { 'Turbo-Frame' => 'admin_user_show' }

      assert_response :success
      assert_select 'form[action=?][method=?][data-turbo-confirm=?]',
                    mfa_tokens_admin_user_path(user), 'post', 'Are you sure?' do
        assert_select 'button', text: 'Delete MFA Tokens'
      end
      assert_select 'form[action=?][method=?][data-turbo-confirm*=?]',
                    deactivate_admin_user_path(user), 'post', 'history will be preserved' do
        assert_select 'button', text: 'Deactivate User'
      end
      assert_select 'button', text: 'Delete User', count: 0
    end

    test 'inactive users offer reactivation' do
      user = create(:constituent, status: :inactive)

      get admin_user_path(user)

      assert_response :success
      assert_select 'form[action=?]', reactivate_admin_user_path(user) do
        assert_select 'button', text: 'Reactivate User'
      end
      assert_select 'form[action=?]', deactivate_admin_user_path(user), count: 0
    end

    test 'index warns inside the results frame when the filters fail, and the next filter clears it' do
      warning = I18n.t('alerts.unfiltered_error')
      frame = { 'Turbo-Frame' => 'users_list' }
      failing_filter = { direction: ['asc'] } # An array makes the service's direction handling raise.

      get admin_users_path
      assert_select "[role='alert']", text: warning, count: 0

      get admin_users_path, params: failing_filter
      assert_response :success
      assert_select "turbo-frame#users_list [role='alert']", text: warning, count: 1
      assert_select "[role='alert']", text: warning, count: 1 # The page shows it once, not also in the layout flash.
      assert_select 'tbody tr'

      get admin_users_path, params: failing_filter, headers: frame # The filter form updates only this frame.
      assert_response :success
      assert_select "turbo-frame#users_list [role='alert']", text: warning, count: 1
      assert_select 'tbody tr'

      get admin_users_path, params: { direction: 'asc' }, headers: frame
      assert_response :success
      assert_select "[role='alert']", text: warning, count: 0
    end

    test 'index shows the first page for an invalid page and raises any other pagination error' do
      get admin_users_path, params: { page: 'abc' }
      assert_response :success

      not_about_the_page = Pagy::VariableError.new(Pagy.new(count: 1), :count, 'to be an Integer >= 0', -1)
      Admin::UsersController.any_instance.stubs(:pagy).raises(not_about_the_page)

      assert_raises(Pagy::VariableError) { get admin_users_path }
    end

    test 'index and show do not surface reset password buttons' do
      user = create(:constituent)

      get admin_users_path, headers: { 'Turbo-Frame' => 'admin_users_index' }
      assert_response :success
      assert_no_match(/Reset Password/i, response.body)

      get admin_user_path(user), headers: { 'Turbo-Frame' => 'admin_user_show' }
      assert_response :success
      assert_no_match(/Reset Password/i, response.body)
    end

    test 'admin can delete all mfa tokens for a user' do
      sign_in_with_fresh_staff_authentication
      user = create(:constituent)
      create(:webauthn_credential, user: user)
      TotpCredential.create!(user: user, nickname: 'Authenticator app', secret: 'secret')
      SmsCredential.create!(user: user, phone_number: '410-555-1234', verified_at: Time.current)
      create_test_session(user)
      create_test_session(user)

      assert_difference -> { Event.where(action: 'admin_user_mfa_tokens_deleted').count }, 1 do
        assert_difference -> { WebauthnCredential.where(user_id: user.id).count }, -1 do
          assert_difference -> { TotpCredential.where(user_id: user.id).count }, -1 do
            assert_difference -> { SmsCredential.where(user_id: user.id).count }, -1 do
              assert_difference -> { Session.where(user_id: user.id).count }, -2 do
                delete mfa_tokens_admin_user_path(user)
              end
            end
          end
        end
      end

      assert_redirected_to admin_user_path(user)
      assert_equal 'Deleted MFA tokens for Test Constituent.', flash[:notice]
      assert_not user.reload.second_factor_enabled?

      event = Event.find_by!(action: 'admin_user_mfa_tokens_deleted', auditable: user)
      assert_equal @admin.id, event.user_id
      assert_equal user.id, event.metadata['target_user_id']
      assert_equal 1, event.metadata.dig('deleted_mfa_credentials', 'webauthn_credentials')
      assert_equal 1, event.metadata.dig('deleted_mfa_credentials', 'totp_credentials')
      assert_equal 1, event.metadata.dig('deleted_mfa_credentials', 'sms_credentials')
      assert_equal 2, event.metadata['deleted_sessions_count']
    end

    test 'admin can delete mfa tokens when none exist' do
      sign_in_with_fresh_staff_authentication
      user = create(:constituent)

      assert_no_difference -> { WebauthnCredential.count + TotpCredential.count + SmsCredential.count } do
        delete mfa_tokens_admin_user_path(user)
      end

      assert_redirected_to admin_user_path(user)
      assert_equal 'No MFA tokens were found for Test Constituent.', flash[:notice]
    end

    test 'admin cannot delete mfa tokens for system user' do
      system_user = ensure_system_audit_actor!
      create(:webauthn_credential, user: system_user)

      assert_difference -> { Event.where(action: 'admin_user_mfa_tokens_blocked').count }, 1 do
        assert_no_difference -> { WebauthnCredential.where(user_id: system_user.id).count } do
          delete mfa_tokens_admin_user_path(system_user)
        end
      end

      assert_redirected_to admin_user_path(system_user)
      assert_equal 'You cannot delete MFA tokens for the system user.', flash[:alert]

      event = Event.find_by!(action: 'admin_user_mfa_tokens_blocked', auditable: system_user)
      assert_equal 'system_user', event.metadata['reason']
    end

    test 'non admin cannot delete mfa tokens' do
      sign_out
      non_admin = create(:constituent)
      user = create(:constituent)
      create(:webauthn_credential, user: user)
      sign_in_for_integration_test non_admin

      assert_no_difference -> { WebauthnCredential.where(user_id: user.id).count } do
        delete mfa_tokens_admin_user_path(user)
      end

      assert_redirected_to root_path
    end

    test 'deactivation preserves application and audit history and revokes sessions' do
      user = create(:constituent)
      application = create(:application, :completed, user: user)
      authored_event = AuditEventService.log(actor: user, action: 'account_history', auditable: application)
      notification = Notification.create!(recipient: user, actor: @admin, action: 'test_notification', notifiable: application)
      user_session = create_test_session(user)

      assert_no_difference ['User.count', 'Application.count', 'Notification.count'] do
        assert_difference -> { Event.where(action: 'user_deactivated', auditable: user).count }, 1 do
          post deactivate_admin_user_path(user)
        end
      end

      assert_redirected_to admin_user_path(user)
      assert user.reload.inactive?
      assert_not Session.exists?(user_session.id)
      assert_equal user.id, authored_event.reload.user_id
      assert_equal user.id, application.reload.user_id
      assert_equal user.id, notification.reload.recipient_id
      event = Event.find_by!(action: 'user_deactivated', auditable: user)
      assert_equal @admin.id, event.user_id
      assert_equal 'active', event.metadata['old_status']
      assert_equal 'inactive', event.metadata['new_status']
      assert_equal 1, event.metadata['revoked_sessions_count']
    end

    test 'reactivation is audited without restoring revoked sessions' do
      user = create(:constituent, status: :inactive)

      assert_difference -> { Event.where(action: 'user_reactivated', auditable: user).count }, 1 do
        assert_no_difference 'Session.count' do
          post reactivate_admin_user_path(user)
        end
      end

      assert_redirected_to admin_user_path(user)
      assert user.reload.public_login_active?
      assert_equal @admin.id, Event.find_by!(action: 'user_reactivated', auditable: user).user_id
    end

    test 'deactivation and session revocation roll back when the audit cannot be recorded' do
      user = create(:constituent)
      user_session = create_test_session(user)
      AuditEventService.stubs(:log).raises(ActiveRecord::RecordInvalid.new(Event.new))

      post deactivate_admin_user_path(user)

      assert_redirected_to admin_user_path(user)
      assert_equal 'The account status could not be changed. No changes were saved.', flash[:alert]
      assert user.reload.active?
      assert Session.exists?(user_session.id)
      assert_not Event.exists?(action: 'user_deactivated', auditable: user)
    end

    test 'repeated deactivation does not create another status audit' do
      user = create(:constituent)
      post deactivate_admin_user_path(user)

      assert_no_difference 'Event.count' do
        post deactivate_admin_user_path(user)
      end

      assert user.reload.inactive?
    end

    test 'a new deactivation after reactivation retains a distinct audit event' do
      user = create(:constituent)
      post deactivate_admin_user_path(user)
      post reactivate_admin_user_path(user)

      assert_difference -> { Event.where(action: 'user_deactivated', auditable: user).count }, 1 do
        post deactivate_admin_user_path(user)
      end
    end

    test 'admin cannot deactivate themself or the system audit account' do
      [@admin, ensure_system_audit_actor!].each do |user|
        get admin_user_path(user)
        assert_response :success
        assert_select 'form[action=?]', deactivate_admin_user_path(user), count: 0
        assert_select 'form[action=?]', reactivate_admin_user_path(user), count: 0
        assert_no_difference 'Event.count' do
          post deactivate_admin_user_path(user)
        end
        assert_redirected_to admin_user_path(user)
        assert user.reload.active?
      end
    end

    test 'reactivation refuses a merged record' do
      user = create(:constituent, status: :inactive, merged_into_user: create(:constituent), merged_by: @admin, merged_at: Time.current)

      get admin_user_path(user)
      assert_response :success
      assert_select 'form[action=?]', reactivate_admin_user_path(user), count: 0

      assert_no_difference 'Event.count' do
        post reactivate_admin_user_path(user)
      end

      assert_redirected_to admin_user_path(user)
      assert user.reload.inactive?
      assert_match(/merged record/, flash[:alert])
    end

    test 'non admin cannot deactivate a user' do
      sign_out
      sign_in_for_integration_test create(:constituent)
      user = create(:admin)

      assert_no_difference 'Event.count' do
        post deactivate_admin_user_path(user)
      end

      assert_redirected_to root_path
      assert user.reload.active?
    end

    test 'show hides retirement actions for current admin and system audit account' do
      [@admin, ensure_system_audit_actor!].each do |user|
        get admin_user_path(user)

        assert_response :success
        assert_select 'form[action=?]', deactivate_admin_user_path(user), count: 0
        assert_select 'form[action=?]', reactivate_admin_user_path(user), count: 0
        assert_select 'button', text: 'Delete User', count: 0
      end
    end

    test 'should create new constituent user as guardian' do
      unique_email = "new.test.guardian.#{Time.now.to_i}@example.com"
      unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

      assert_difference('Users::Constituent.count') do
        post admin_users_path, params: {
          first_name: 'New',
          last_name: 'Guardian',
          email: unique_email,
          phone: unique_phone,
          date_of_birth: Date.new(1990, 1, 15),
          physical_address_1: '123 Maple Street',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          communication_preference: 'email'
        }, as: :json
      end

      assert_response :success
      json_response = response.parsed_body
      assert json_response['success']
      assert_equal 'New', json_response['user']['first_name']
      assert_equal 'Guardian', json_response['user']['last_name']

      # Verify user was created properly
      user = Users::Constituent.find_by(email: unique_email)
      assert user.present?
      assert user.force_password_change?
      assert user.verified?

      markers = session[PaperQuickCreatePortalMarkers::SESSION_KEY]
      assert_equal ['stored_at'], markers[user.id.to_s].keys
    end

    test 'should handle validation errors' do
      assert_no_difference('Users::Constituent.count') do
        post admin_users_path, params: {
          # Missing required fields
          first_name: '',
          last_name: '',
          email: 'invalid-email',
          phone: '555-555-5555'
        }, as: :json
      end

      assert_response :unprocessable_content
      assert_select '[role=alert]', text: /Failed|invalid|required/i
    end

    test 'admin quick create soft duplicate records selection and keep-separate in resolved cases' do
      existing_user = Users::Constituent.create!(
        first_name: 'Test',
        last_name: 'Duplicate',
        email: "first.user.#{Time.now.to_i}@example.com",
        phone: '555-111-1111',
        date_of_birth: Date.parse('1995-06-11'),
        physical_address_1: '456 First St',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        communication_preference: 'email',
        password: SecureRandom.hex(8),
        verified: true
      )

      create_params = {
        first_name: 'Test',
        last_name: 'Duplicate',
        date_of_birth: '1995-06-11',
        email: "second.duplicate.#{SecureRandom.hex(4)}@example.com",
        phone: "555-#{rand(100..999)}-#{rand(1000..9999)}",
        physical_address_1: '123 Main St',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21202',
        communication_preference: 'email'
      }

      historical_cases = %i[admin_create paper_intake].map do |source|
        DuplicateReviewCase.create!(
          source: source,
          subject_user: existing_user,
          deduplication_key: SecureRandom.hex(16),
          metadata: { 'reason_codes' => ['name_dob'] },
          opened_at: 2.days.ago,
          status: :open
        )
      end
      historical_snapshots = historical_cases.to_h { |review_case| [review_case.id, review_case.attributes.deep_dup] }

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                            'Event.count', 'Notification.count'] do
        post admin_users_path, params: create_params, as: :json
      end
      assert_response :unprocessable_content
      receipt = css_select('input[name=guardian_identity_review_receipt]').sole['value']
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_select 'button[name=selected_candidate_id][value=?]', existing_user.id
      assert receipt.present?

      assert_no_difference 'User.count' do
        assert_difference 'DuplicateReviewCase.count', 1 do
          post admin_users_path, params: create_params.merge(
            selected_candidate_id: existing_user.id, identity_review_receipt: receipt,
            identity_rationale: 'Staff confirmed the existing guardian.'
          ), as: :json
        end
      end
      assert_response :success
      selected = response.parsed_body
      assert_equal 'selected', selected['state']
      assert_equal existing_user.id, selected.dig('user', 'id')

      assert_difference 'User.count', 1 do
        assert_difference -> { Event.where(action: 'duplicate_review_case_resolved').count }, 1 do
          assert_difference ['DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count'], 1 do
            post admin_users_path, params: create_params.merge(
              identity_review_receipt: receipt, identity_determination: 'keep_separate',
              identity_rationale: 'Staff confirmed a different guardian.'
            ), as: :json
          end
        end
      end
      assert_response :success
      created = User.find(response.parsed_body.dig('user', 'id'))
      assert_equal create_params[:email], created.email
      assert_not created.needs_duplicate_review

      review_case = DuplicateReviewCase.find_by!(subject_user: created)
      assert review_case.resolved_ignored?
      assert_equal @admin.id, review_case.resolved_by_id
      assert_equal 'guardian', review_case.metadata['intake_role']
      assert_equal [existing_user.id], review_case.duplicate_review_case_candidates.pluck(:candidate_user_id)
      historical_cases.each do |review_case|
        assert_equal historical_snapshots.fetch(review_case.id), review_case.reload.attributes,
                     "A2 must not mutate historical #{review_case.source} evidence"
      end
    end

    test 'admin quick create hard duplicate contact blocks before persistence without workflow side effects' do
      existing = create(:constituent, phone: "410-555-#{SecureRandom.random_number(9000) + 1000}")

      assert_no_difference ['User.count', 'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count', 'Event.count'] do
        post admin_users_path, params: {
          first_name: 'Different',
          last_name: 'Guardian',
          email: "quick-create-#{SecureRandom.hex(4)}@example.com",
          phone: existing.phone,
          physical_address_1: '100 Mail Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          date_of_birth: '01/01/1980',
          communication_preference: 'email'
        }, as: :json
      end

      assert_response :unprocessable_content
      assert_select '[role=alert]', text: /email|phone|already exists/i
      assert_not existing.reload.needs_duplicate_review
    end

    test 'admin quick create contact-index race rolls back and re-runs the canonical review' do
      contact_owner = create(:constituent, email: "race-owner-#{SecureRandom.hex(4)}@example.com")
      attrs = {
        first_name: 'Different', last_name: 'Guardian', date_of_birth: '01/01/1980',
        email: contact_owner.email, phone: "410-555-#{SecureRandom.random_number(9000) + 1000}",
        physical_address_1: '4 Race Way', city: 'Baltimore', state: 'MD', zip_code: '21201',
        communication_preference: 'email'
      }
      clear_review = Applications::PaperIdentityReview::Result.new(
        state: :clear, candidates: [], selectable_candidates: [], presented_candidates: [],
        reasons: [], token: nil, decision_reason: nil, identity_facts: attrs
      )
      blocked_review = Applications::PaperIdentityReview::Result.new(
        state: :blocked, candidates: [contact_owner], selectable_candidates: [contact_owner],
        presented_candidates: [{ id: contact_owner.id, name: contact_owner.full_name, selectable: true }],
        reasons: ['exact_email'], token: nil, decision_reason: nil, identity_facts: attrs
      )
      Applications::PaperIdentityReview.any_instance.stubs(:call).returns(clear_review, blocked_review)
      Applications::UserCreationService.any_instance.stubs(:call).raises(
        ActiveRecord::RecordNotUnique.new('index_users_on_email_unique')
      )

      assert_no_difference ['User.count', 'GuardianRelationship.count', 'Application.count',
                            'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                            'Event.count', 'Notification.count'] do
        post admin_users_path, params: attrs, as: :json
      end

      assert_response :unprocessable_content
      assert_select 'button[name=selected_candidate_id][value=?]', contact_owner.id
      assert_select '[role=alert]', text: /changed while saving/i
    end

    test 'admin quick create split exact contacts cannot select either owner' do
      email_owner = create(:constituent, email: "split-guardian-#{SecureRandom.hex(4)}@example.com")
      phone_owner = create(:constituent, phone: "410-555-#{SecureRandom.random_number(9000) + 1000}")
      attrs = {
        first_name: 'Split', last_name: 'Guardian', date_of_birth: '01/01/1980',
        email: email_owner.email, phone: phone_owner.phone,
        physical_address_1: '2 Split Way', city: 'Baltimore', state: 'MD', zip_code: '21201',
        communication_preference: 'email'
      }
      refused_writes = ['User.count', 'GuardianRelationship.count', 'Application.count',
                        'DuplicateReviewCase.count', 'DuplicateReviewCaseCandidate.count',
                        'Event.count', 'Notification.count']

      assert_no_difference refused_writes do
        post admin_users_path, params: attrs, as: :json
      end
      assert_response :unprocessable_content
      assert_select 'button[name=selected_candidate_id]', count: 0
      assert_select 'button[name=identity_determination]', count: 0

      assert_no_difference refused_writes do
        post admin_users_path, params: attrs.merge(selected_candidate_id: email_owner.id), as: :json
      end
      assert_response :unprocessable_content
      assert_select '[role=alert]'
    end

    test 'quick create rejects tampered decisions and revalidates selected guardians under lock' do
      survivor = create(:constituent)
      existing = create(:constituent, first_name: 'Locked', last_name: 'Guardian',
                                      date_of_birth: Date.new(1980, 1, 1))
      attrs = {
        first_name: 'Locked', last_name: 'Guardian', date_of_birth: '01/01/1980',
        email: "locked-#{SecureRandom.hex(4)}@example.com", phone: '555-901-4422',
        physical_address_1: '1 Lock Way', city: 'Baltimore', state: 'MD', zip_code: '21201',
        communication_preference: 'email'
      }

      post admin_users_path, params: attrs, as: :json
      token = css_select('input[name=guardian_identity_review_receipt]').sole['value']
      assert token.present?

      assert_no_difference ['User.count', 'DuplicateReviewCase.count', 'Event.count'] do
        post admin_users_path, params: attrs.merge(identity_review_receipt: "#{token}tampered"), as: :json
      end
      assert_response :unprocessable_content
      assert_select '#guardian-review-heading'

      assert_no_difference ['User.count', 'DuplicateReviewCase.count', 'Event.count'] do
        post admin_users_path,
             params: attrs.merge(last_name: 'Changed', identity_review_receipt: token), as: :json
      end
      assert_response :unprocessable_content
      assert_select '[role=alert]', text: /changed|Review again/i

      existing.update!(merged_into_user: survivor)
      assert_no_difference ['User.count', 'DuplicateReviewCase.count', 'Event.count'] do
        post admin_users_path, params: attrs.merge(selected_candidate_id: existing.id), as: :json
      end
      assert_response :unprocessable_content
      assert_select '[role=alert]'
    end

    test 'quick create guardian without email or phone succeeds for address-only intake' do
      assert_difference 'User.count', 1 do
        post admin_users_path, params: {
          first_name: 'Letter',
          last_name: 'Guardian',
          guardian_no_email_address: '1',
          guardian_no_phone_number: '1',
          no_email_address: '1',
          no_phone_number: '1',
          email: 'ignored@example.com',
          phone: '555-000-9999',
          physical_address_1: '100 Mail Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          date_of_birth: '01/01/1980',
          communication_preference: 'letter'
        }, as: :json
      end

      assert_response :success
      user = User.order(:created_at).last
      assert_nil user.email
      assert_nil user.phone
      assert user.deliver_via_letter?
      assert_not user.portal_access_eligible?
      assert_empty(session[PaperQuickCreatePortalMarkers::SESSION_KEY] || {})
    end

    test 'admin can update address-only user profile without email' do
      user = nil
      internal_password = SecureRandom.hex(32)
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'Letter', last_name: 'Only',
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      patch admin_user_path(user), params: {
        user: {
          first_name: 'Updated',
          last_name: 'Only',
          email: '',
          phone: '',
          physical_address_1: '200 Mail Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          communication_preference: 'letter'
        }
      }

      assert_redirected_to admin_user_path(user)
      user.reload
      assert_equal 'Updated', user.first_name
      assert_nil user.email
      assert_nil user.phone
    end

    %i[inactive suspended].each do |status|
      test "admin can edit an unmerged #{status} user profile" do
        user = create(:constituent)
        user.update!(status: status)

        patch admin_user_path(user), params: {
          user: {
            first_name: 'Updated',
            last_name: user.last_name,
            email: user.email,
            phone: user.phone,
            phone_type: user.phone_type
          }
        }

        assert_redirected_to admin_user_path(user)
        assert_equal 'Updated', user.reload.first_name
        assert_predicate user, :"#{status}?"
      end

      test "verified staff can correct an unmerged #{status} contact without reactivating the user" do
        sign_in_with_fresh_staff_authentication
        user = create(:constituent)
        Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'Existing target session')
        user.update!(status: status)
        original_email = user.email
        original_version = user.security_version
        staff_session_ids = @admin.sessions.pluck(:id)

        assert_difference 'ContactChangeRequest.count', 1 do
          patch admin_user_path(user), params: {
            user: { phone: '410-555-0183', phone_type: 'voice' },
            contact_verification: {
              identity_verified: '1', association_verified: '1', method: 'Approved non-SMS check', reference: 'CASE-STATUS-123'
            }
          }
        end

        assert_redirected_to admin_user_path(user)
        assert_equal '410-555-0183', user.reload.phone
        assert_equal 'voice', user.phone_type
        assert_equal original_email, user.email
        assert_predicate user, :"#{status}?"
        assert_not user.public_login_active?
        assert_equal original_version + 1, user.security_version
        assert_empty user.sessions
        assert_equal staff_session_ids, @admin.sessions.pluck(:id)
        change = ContactChangeRequest.where(user_id: user.id).sole
        assert change.completed_at
        event = Event.find_by!(action: 'account_contact_change_completed', auditable: user)
        assert_equal 'CASE-STATUS-123', event.metadata.dig('verification', 'reference')
      end
    end

    %i[exception pending].each do |notice_failure|
      test "a saved staff contact change remains committed when its notice followup has #{notice_failure}" do
        sign_in_with_fresh_staff_authentication
        user = create(:constituent)
        previous_version = user.security_version
        target_session = Session.create!(user: user, ip_address: '127.0.0.1', user_agent: 'Existing target session')
        staff_sessions = @admin.sessions.pluck(:id)
        if notice_failure == :exception
          ContactChangeRequest.any_instance.expects(:enqueue_deliveries!).raises(ActiveRecord::RecordInvalid)
        else
          ContactChangeRequest.any_instance.expects(:enqueue_deliveries!).returns(false)
        end

        patch admin_user_path(user), params: {
          user: { first_name: 'Committed staff edit', phone: '410-555-0185', phone_type: 'voice' },
          contact_verification: {
            identity_verified: '1', association_verified: '1', method: 'Approved non-SMS check', reference: 'CASE-NOTICE-123'
          }
        }

        assert_response :see_other
        assert_redirected_to admin_user_path(user)
        assert_match(/User was saved/, flash[:alert])
        assert_match(/notices could not be confirmed as queued/, flash[:alert])
        assert_no_match(/No changes were saved/, response.body)
        assert_nil flash[:notice]
        assert_equal 'Committed staff edit', user.reload.first_name
        assert_equal '410-555-0185', user.phone
        assert_equal previous_version + 1, user.security_version
        assert_not Session.exists?(target_session.id)
        assert_empty user.sessions
        assert_equal staff_sessions, @admin.sessions.pluck(:id)
        change = ContactChangeRequest.where(user_id: user.id).sole
        assert change.completed_at
        assert_equal 'pending', change.delivery_states['old_completed']
        assert Event.exists?(action: 'account_contact_change_completed', auditable: user)
      end
    end

    test 'recorded staff proof cannot change merged or system audit contacts' do
      sign_in_with_fresh_staff_authentication
      retired = create(:constituent, status: :inactive, merged_into_user: create(:constituent), merged_by: @admin, merged_at: Time.current)
      system_actor = ensure_system_audit_actor!

      [retired, system_actor].each do |user|
        original_contacts = user.attributes.slice('email', 'phone', 'phone_type', 'security_version', 'status')
        assert_no_difference ['ContactChangeRequest.count', 'Event.count'] do
          patch admin_user_path(user), params: {
            user: { phone: '410-555-0184', phone_type: 'voice' },
            contact_verification: {
              identity_verified: '1', association_verified: '1', method: 'Approved non-SMS check', reference: 'CASE-REFUSAL-123'
            }
          }
        end
        if user == retired
          assert_redirected_to admin_user_path(user)
        else
          assert_response :unprocessable_content
        end
        assert_equal original_contacts, user.reload.attributes.slice(*original_contacts.keys)
      end
    end

    test 'admin cannot clear all contact information outside paper intake' do
      sign_in_with_fresh_staff_authentication
      user = create(:constituent, email: generate(:email), phone: '410-555-0100')

      patch admin_user_path(user), params: {
        contact_verification: { identity_verified: '1', association_verified: '1', method: 'Approved check', reference: 'CASE-123' },
        user: {
          first_name: user.first_name,
          last_name: user.last_name,
          email: '',
          phone: '',
          communication_preference: 'letter',
          physical_address_1: user.physical_address_1,
          city: user.city,
          state: user.state,
          zip_code: user.zip_code
        }
      }

      assert_response :unprocessable_content
      user.reload
      assert user.real_email?
      assert user.real_phone?
    end

    test 'admin cannot set email delivery without email on file' do
      sign_in_with_fresh_staff_authentication
      user = create(:constituent, email: generate(:email), phone: '410-555-0100')

      patch admin_user_path(user), params: {
        contact_verification: { identity_verified: '1', association_verified: '1', method: 'Approved check', reference: 'CASE-123' },
        user: {
          first_name: user.first_name,
          last_name: user.last_name,
          email: '',
          phone: user.phone,
          communication_preference: 'email',
          physical_address_1: user.physical_address_1,
          city: user.city,
          state: user.state,
          zip_code: user.zip_code
        }
      }

      assert_response :unprocessable_content
      user.reload
      assert user.real_email?
    end

    test 'staff users cannot be made address-only through admin edit' do
      sign_in_with_fresh_staff_authentication
      staff = create(:admin, email: generate(:email), phone: '410-555-0199')

      patch admin_user_path(staff), params: {
        contact_verification: { identity_verified: '1', association_verified: '1', method: 'Approved check', reference: 'CASE-123' },
        user: {
          first_name: staff.first_name,
          last_name: staff.last_name,
          email: '',
          phone: '',
          communication_preference: 'letter',
          physical_address_1: staff.physical_address_1,
          city: staff.city,
          state: staff.state,
          zip_code: staff.zip_code
        }
      }

      assert_response :unprocessable_content
      staff.reload
      assert staff.real_email?
      assert staff.real_phone?
    end

    test 'admin update rejects malformed email for address-only user' do
      sign_in_with_fresh_staff_authentication
      user = nil
      internal_password = SecureRandom.hex(32)
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'Letter', last_name: 'Only',
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      patch admin_user_path(user), params: {
        contact_verification: { identity_verified: '1', association_verified: '1', method: 'Approved check', reference: 'CASE-123' },
        user: {
          first_name: 'Letter',
          last_name: 'Only',
          email: 'not-an-email',
          phone: '',
          physical_address_1: '100 Mail Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          communication_preference: 'letter'
        }
      }

      assert_response :unprocessable_content
      user.reload
      assert_nil user.email
    end

    test 'constituents list includes constituents with archived applications' do
      archived = create(:constituent, email: generate(:email), first_name: 'ArchivedListed')
      create(:application, :archived, user: archived)

      get constituents_admin_users_path

      assert_response :success
      assert_match 'ArchivedListed', response.body
    end

    test 'constituents list shows no email on file for address-only users' do
      internal_password = SecureRandom.hex(32)
      user = nil
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'Inactive', last_name: 'LetterOnly',
          status: :inactive,
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      create(:application, :archived, user: user)

      get constituents_admin_users_path

      assert_response :success
      assert_match ConstituentCommunicationLabelsHelper::NO_EMAIL_ON_FILE, response.body
    end

    test 'history shows display helpers for address-only users' do
      user = nil
      internal_password = SecureRandom.hex(32)
      Current.paper_context = true
      begin
        user = Users::Constituent.create!(
          first_name: 'History', last_name: 'LetterOnly',
          status: :inactive,
          communication_preference: :letter,
          physical_address_1: '100 Mail Lane', city: 'Baltimore', state: 'MD', zip_code: '21201',
          date_of_birth: Date.new(1960, 1, 1),
          password: internal_password, password_confirmation: internal_password,
          hearing_disability: true
        )
      ensure
        Current.reset
      end

      get history_admin_user_path(user)

      assert_response :success
      assert_match ConstituentCommunicationLabelsHelper::NO_EMAIL_ON_FILE, response.body
      assert_match ConstituentCommunicationLabelsHelper::NO_PHONE_ON_FILE, response.body
    end

    private

    def sign_in_with_fresh_staff_authentication
      sign_out
      @admin.update!(password: 'FreshStaffPassword123!', password_confirmation: 'FreshStaffPassword123!')
      credential = @admin.totp_credentials.create!(secret: ROTP::Base32.random, nickname: 'Staff app', last_used_at: 1.minute.ago)
      post sign_in_path, params: { contact: @admin.email, password: 'FreshStaffPassword123!' }
      assert_response :redirect
      post process_verification_two_factor_authentication_path(type: 'totp'),
           params: { code: ROTP::TOTP.new(credential.secret).now }, as: :json
      assert_response :success
    end
  end
end
