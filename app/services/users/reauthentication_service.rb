# frozen_string_literal: true

module Users
  class ReauthenticationService
    Result = Data.define(:session_record, :error) do
      def success? = session_record.present?
    end

    def initialize(user:, session_record:, token:)
      @user = user
      @session_record = session_record
      @token = token
    end

    def prepare(password:)
      with_password(password) do |user, record|
        {
          'user_id' => user.id, 'session_id' => record.id,
          'token_digest' => Session.digest_token(@token), 'security_version' => user.security_version,
          'nonce' => SecureRandom.hex(24), 'expires_at' => Session::REAUTHENTICATION_WINDOW.from_now.to_i
        }
      end
    end

    def call(password:, factor:, context: nil, code: nil, assertion: nil, credential_id: nil)
      sms_result = check_sms(password, context, code, credential_id) if factor == 'sms'
      return failure(:invalid) if factor == 'sms' && sms_result != 'approved'

      with_password(password) do |user, record|
        next failure(:invalid) unless factor_verified?(user, record, factor, context, code, assertion)

        record.rotate_after_authentication!(user: user)
        AuditEventService.log(action: 'session_reauthenticated', actor: user, auditable: record,
                              metadata: { session_id: record.id, factor: factor.presence || 'password', operation_id: SecureRandom.uuid })
        Result.new(session_record: record, error: nil)
      end || failure(:invalid)
    end

    private

    def with_password(password)
      ActiveRecord::Base.transaction do
        user = User.lock_for_merge_integrity!(@user).fetch(@user.id)
        @session_record.require_live!(token: @token, user: user)
        next if user.account_locked?

        unless user.authenticate(password)
          user.record_failed_login!
          next
        end

        yield user, @session_record
      end
    end

    def factor_verified?(user, record, factor, context, code, assertion)
      return factor.blank? || factor == 'password' unless user.second_factor_enabled?

      case factor
      when 'totp' then user.verify_totp(code) == :verified
      when 'webauthn'
        valid_context?(context, user, record, 'webauthn') &&
          user.verify_webauthn(assertion, challenge: context['challenge']).present?
      when 'sms'
        valid_context?(context, user, record, 'sms') &&
          user.sms_credentials.verified.exists?(id: context['credential_id'])
      else false
      end
    end

    def check_sms(password, context, code, credential_id)
      credential = with_password(password) do |user, record|
        next unless valid_context?(context, user, record, 'sms')
        next unless context['credential_id'].to_s == credential_id.to_s

        user.sms_credentials.verified.find_by(id: context['credential_id'])
      end
      return unless credential

      result = TwilioVerifyService.check_verification(
        credential.phone_number, code,
        verification_sid: context['verification_sid'],
        purpose: :reauthentication, owner: context['owner']
      )
      result[:status] if result[:success]
    end

    def valid_context?(context, user, record, type)
      context.is_a?(Hash) && context['type'] == type && context['user_id'] == user.id &&
        context['session_id'] == record.id && context['token_digest'] == Session.digest_token(@token) &&
        context['security_version'] == user.security_version && context['expires_at'].to_i > Time.current.to_i
    end

    def failure(error) = Result.new(session_record: nil, error: error)
  end
end
