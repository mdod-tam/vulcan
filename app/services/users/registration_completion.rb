# frozen_string_literal: true

module Users
  class RegistrationCompletion
    class RequiredReviewUnavailable < StandardError; end

    Result = Data.define(:status, :user)

    def initialize(token:, attributes:, actor: nil)
      @token = token
      @attributes = attributes
      @actor = actor
    end

    def call
      @verification = RegistrationVerification.resolve(@token)
      return Result.new(status: :invalid, user: nil) unless @verification

      @user = Users::Constituent.new(@attributes)
      @user.assign_attributes(email: @verification.email, phone: nil, phone_type: :contact_email,
                              email_verified: true, force_password_change: false)
      @user.portal_self_registration = true
      status = nil
      @verification.with_lock do
        if !@verification.active?
          status = :invalid
        elsif User.find_by_email(@verification.email)
          status = :existing
          @verification.update!(consumed_at: Time.current)
        else
          save_registration!
          @verification.update!(consumed_at: Time.current, created_user: @user)
          status = :complete
        end
      end
      Result.new(status: status, user: @user)
    rescue StandardError => e
      Rails.logger.warn("Registration completion failed: #{e.class.name}")
      result_after_failure
    end

    private

    def save_registration!
      detection = DuplicateDetectionService.new(
        context: :public_registration,
        attrs: DuplicateDetectionService.identity_facts(@user.attributes)
      ).call
      raise RequiredReviewUnavailable unless detection.success? && !detection.data.hard_block

      Current.set(user: @actor || @user) { @user.save! }
      record_duplicate_review!(detection.data) if detection.data.recommended_action == :flag
      event = AuditEventService.log(action: 'registration_email_verified', actor: @actor || @user,
                                    auditable: @user, metadata: { registration_verification_id: @verification.id })
      raise RequiredReviewUnavailable unless event
    end

    def record_duplicate_review!(detection)
      actor = PublicAuditActor.system_audit_actor
      raise RequiredReviewUnavailable unless actor

      candidates = detection.matched_users.map do |candidate|
        DuplicateReviewCases::CreateService::CandidateInput.new(candidate, detection.reasons.first)
      end
      result = DuplicateReviewCases::CreateService.new(
        source: :registration_soft_match, subject_user: @user, actor: actor,
        reason_codes: detection.reasons, candidates: candidates,
        metadata: { intake_context: 'registration' }
      ).call
      raise RequiredReviewUnavailable unless result.success?
    end

    # A callback can raise after commit. The consumed proof records whether creation committed.
    def result_after_failure
      if @verification
        @verification.reload
        return Result.new(status: :complete, user: @verification.created_user) if @verification.created_user_id
        return Result.new(status: :existing, user: nil) if @verification.consumed_at
      end
      status = @user&.errors&.any? ? :validation_failed : :failed
      Result.new(status: status, user: @user)
    rescue StandardError
      Result.new(status: :uncertain, user: nil)
    end
  end
end
