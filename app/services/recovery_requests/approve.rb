# frozen_string_literal: true

module RecoveryRequests
  class Approve
    class Refused < StandardError
      attr_reader :status

      def initialize(status)
        @status = status
        super(status.to_s)
      end
    end

    Result = Data.define(:status, :request, :notification)

    def initialize(recovery_request:, actor:, session_record:, token:, verification:)
      @request = recovery_request
      @actor = actor
      @session = session_record
      @token = token
      @verification = verification.to_h.symbolize_keys.slice(
        :verification_method, :verification_result, :verification_reference, :identity_check_completed
      )
    end

    def call
      ActiveRecord::Base.transaction { approve_under_lock! }
      notice_outcome = DispatchApprovalNotice.new(@request).call
      Result.new(status: notice_outcome == :failed ? :approved_notice_failed : :approved,
                 request: @request, notification: @notification)
    rescue Refused => e
      Result.new(status: e.status, request: @request, notification: nil)
    end

    private

    def approve_under_lock!
      users = User.lock_for_merge_integrity!(@actor.id, @request.user_id)
      @actor = users.fetch(@actor.id)
      raise Refused, :unauthorized unless @actor.admin? && @actor.public_login_active?

      @request.reload(lock: true)
      subject = users.fetch(@request.user_id)
      raise Refused, :self_approval if @actor.id == subject.id
      raise Refused, :ineligible unless subject.public_login_active?
      raise Session::AuthenticationRequired unless @session

      @session.require_recent_authentication!(token: @token, user: @actor)
      raise Refused, :not_pending unless @request.pending?

      approved_at = Time.current
      @request.assign_attributes(@verification)
      raise Refused, :invalid unless @request.valid?(:approval)

      @request.update!(status: 'approved', resolved_at: approved_at, resolved_by: @actor)

      metadata = revoke_access!(subject, approved_at)
      metadata.merge!(approval_metadata(subject, approved_at))
      audit = AuditEventService.log(action: 'security_key_recovery_approved', actor: @actor,
                                    auditable: @request, metadata: metadata)
      raise ActiveRecord::RecordNotSaved, 'Recovery approval audit was not recorded' unless audit&.persisted?

      @notification = NotificationService.create_and_deliver!(type: 'security_key_recovery_approved', recipient: subject,
                                                              actor: @actor, notifiable: @request, metadata: metadata,
                                                              channel: :email, deliver: false)
      raise ActiveRecord::RecordNotSaved, 'Recovery notice was not recorded' unless @notification&.persisted?

      context = EmailDelivery::Policy.capture(mail_action: 'ApplicationNotificationsMailer#security_key_recovery_approved',
                                              params: { notification_id: @notification.id })
      @notification.update!(metadata: @notification.metadata.merge('recovery_delivery_context' => context))
    end

    def revoke_access!(subject, approved_at)
      credentials = subject.webauthn_credentials.order(:id).lock.to_a
      sessions = subject.sessions.order(:id).lock.to_a
      contact_requests = ContactChangeRequest.where(user_id: subject.id, completed_at: nil, canceled_at: nil).order(:id).lock.to_a
      credentials.each(&:destroy!)
      sessions.each(&:destroy!)
      contact_requests.each { |request| request.update!(canceled_at: approved_at) }
      subject.advance_security_version!
      {
        removed_webauthn_credential_ids: credentials.map(&:id), removed_webauthn_credential_count: credentials.size,
        retained_factor_counts: { totp: subject.totp_credentials.count, sms: subject.sms_credentials.count },
        revoked_session_count: sessions.size,
        canceled_contact_request_ids: contact_requests.map(&:id), canceled_contact_request_count: contact_requests.size
      }
    end

    def approval_metadata(subject, approved_at)
      {
        recovery_request_id: @request.id, subject_user_id: subject.id, approved_at: approved_at.iso8601,
        approved_by: @actor.full_name, verification_method: @request.verification_method,
        verification_result: @request.verification_result, verification_reference: @request.verification_reference
      }
    end
  end
end
