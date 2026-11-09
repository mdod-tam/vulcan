# frozen_string_literal: true

module Users
  # The primary contact writer for authenticated self service and recorded staff
  # verification. Paper intake and duplicate merging retain their domain owners.
  class ContactChange
    def self.primary_attributes_changed?(user, attributes)
      attrs = attributes.to_h.stringify_keys
      (attrs.key?('email') && User.normalize_email(attrs['email']) != user.email) ||
        (attrs.key?('phone') && normalized_phone(attrs['phone']) != user.phone) ||
        (attrs.key?('phone_type') && (User.phone_types.key(attrs['phone_type']) || attrs['phone_type']) != user.phone_type)
    end

    def self.normalized_phone(value)
      value.present? ? PhoneNumber.normalize(value) || value.to_s.strip : nil
    end

    def initialize(user:, actor:, session:, token:)
      @user = user
      @actor = actor
      @session = session
      @token = token
    end

    def request!(attributes)
      row = nil
      User.transaction do
        lock_users!
        require_self!
        cancel_pending!
        row = build_request(attributes)
        row.prepare_requested_deliveries!
        row.save!
        audit!('account_contact_change_requested', row)
      end
      row
    end

    def complete!(row)
      User.transaction do
        lock_users!
        require_self!
        row.lock!
        row.require_current!(locked_user: @user)
        raise ContactChangeRequest::Refused unless row.session_id == @session.id && row.ready? && !row.staff_assistance?

        promote!(row)
      end
      row
    end

    def resend!(row)
      User.transaction do
        lock_users!
        require_self!
        row.lock!
        row.require_current!(locked_user: @user)
        raise ContactChangeRequest::Refused unless row.session_id == @session.id

        row.prepare_requested_deliveries!
        row.save!
      end
      row
    end

    def confirm_sms!(row, code:)
      authorize_request!(row)
      result = TwilioVerifyService.check_verification(row.proposed_value, code, verification_sid: row.sms_verification_sid,
                                                                                purpose: :contact_change, owner: row.sms_owner)
      raise ContactChangeRequest::Refused unless result[:success] && result[:status] == 'approved'

      User.transaction do
        lock_users!
        require_self!
        row.lock!
        row.require_current!(locked_user: @user)
        raise ContactChangeRequest::Refused unless row.session_id == @session.id && row.sms? && row.sms_expires_at&.future?

        row.update!(new_confirmed_at: Time.current)
        audit!('account_contact_ownership_confirmed', row, proof: 'sms')
      end
      row
    end

    def send_sms!(row)
      authorize_request!(row)
      raise ContactChangeRequest::Refused unless row.sms?

      result = TwilioVerifyService.send_verification(row.proposed_value, purpose: :contact_change, owner: row.sms_owner, locale: row.locale)
      raise ContactChangeRequest::Refused unless result[:success] && result[:verification_sid].present?

      User.transaction do
        lock_users!
        require_self!
        row.lock!
        row.require_current!(locked_user: @user)
        row.update!(sms_verification_sid: result[:verification_sid],
                    sms_expires_at: [row.expires_at, Time.zone.at(result.fetch(:code_expires_at))].min)
      end
      row
    end

    def staff_update!(attributes, verification:)
      rows = []
      User.transaction do
        lock_users!
        raise ContactChangeRequest::Refused unless @actor.admin? && @actor.id != @user.id
        raise ContactChangeRequest::Refused if @user.merged? || @user.system_audit_account?

        require_staff_proof!(verification)
        cancel_pending!
        changes = contact_changes(attributes)
        @user.update!(attributes.except('email', 'phone', 'phone_type'))
        changes.each do |attrs|
          row = build_request(attrs)
          row.old_confirmation_required = false
          row.new_confirmed_at = Time.current
          row.old_confirmed_at = Time.current
          row.save!
          promote!(row, proof: staff_proof_metadata(verification))
          rows << row
        end
      end
      rows
    end

    def authorize_request!(row)
      User.transaction do
        lock_users!
        require_self!
        row.lock!
        row.require_current!(locked_user: @user)
        raise ContactChangeRequest::Refused unless row.session_id == @session.id
      end
    end

    private

    def lock_users!
      users = User.lock_for_merge_integrity!(@user, @actor)
      @user = users.fetch(@user.id)
      @actor = users.fetch(@actor.id)
      @session.require_recent_authentication!(token: @token, user: @actor)
    end

    def require_self!
      raise ContactChangeRequest::Refused unless @actor.id == @user.id && @user.public_login_active?
    end

    def build_request(attributes)
      attrs = attributes.to_h.with_indifferent_access
      kind = attrs[:kind].to_s
      row = ContactChangeRequest.new(user: @user, session: @session, kind: kind,
                                     old_value: kind == 'email' ? @user.email : @user.phone,
                                     proposed_value: attrs[:proposed_value], phone_type: attrs[:phone_type],
                                     notification_email: @user.real_email? ? @user.email : nil,
                                     locale: @user.effective_message_locale.to_s, security_version: @user.security_version,
                                     old_confirmation_required: kind == 'email' && !@user.second_factor_enabled?,
                                     expires_at: ContactChangeRequest::LIFETIME.from_now)
      row.validate!
      raise ContactChangeRequest::Refused if row.proposed_value == row.old_value && (kind == 'email' || row.phone_type == @user.phone_type)

      row
    end

    def contact_changes(attributes)
      changes = []
      changes << { kind: 'email', proposed_value: attributes['email'] } if attributes.key?('email') && User.normalize_email(attributes['email']) != @user.email
      if (attributes.key?('phone') && self.class.normalized_phone(attributes['phone']) != @user.phone) ||
         (attributes.key?('phone_type') && attributes['phone_type'] != @user.phone_type)
        changes << { kind: 'phone', proposed_value: attributes.fetch('phone', @user.phone),
                     phone_type: attributes.fetch('phone_type', @user.phone_type) }
      end
      changes
    end

    def promote!(row, proof: nil)
      attributes = if row.kind == 'email'
                     { email: row.proposed_value }
                   else
                     { phone: row.proposed_value, phone_type: row.proposed_value.present? ? row.phone_type : 'contact_email' }
                   end
      @user.update!(attributes)
      @user.advance_security_version!
      row.completed_at = Time.current
      row.prepare_completed_deliveries!
      row.save!
      sessions_count = @user.sessions.count
      audit!('account_contact_change_completed', row, revoked_sessions_count: sessions_count, verification: proof)
      @user.sessions.reload.each(&:destroy!)
    end

    def cancel_pending!
      ContactChangeRequest.unresolved.where(user_id: @user.id).find_each do |row|
        row.update!(canceled_at: Time.current)
        audit!('account_contact_change_canceled', row)
      end
    end

    def require_staff_proof!(verification)
      data = verification.to_h.with_indifferent_access
      truth = ActiveModel::Type::Boolean.new
      unless truth.cast(data[:identity_verified]) && truth.cast(data[:association_verified]) &&
             data[:method].to_s.strip.length.between?(3, 120) && data[:reference].to_s.strip.length.between?(3, 240)
        raise ContactChangeRequest::Refused
      end
    end

    def staff_proof_metadata(verification)
      data = verification.to_h.with_indifferent_access
      { method: data[:method].to_s.strip, reference: data[:reference].to_s.strip,
        identity_verified: true, new_contact_association_verified: true }
    end

    def audit!(action, row, **extra)
      AuditEventService.log(action: action, actor: @actor, auditable: @user,
                            metadata: { operation_id: "contact-change:#{row.id}:#{action}", contact_change_request_id: row.id, kind: row.kind,
                                        target_digest: AuthRateLimit.contact_digest(row.proposed_value) }.merge(extra))
    end
  end
end
