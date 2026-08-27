# frozen_string_literal: true

module Applications
  # The single owner of "what does a search for this paper applicant turn up, and what may staff do
  # about it".
  #
  # Two callers need that answer and they must never disagree: the read-only review the admin form
  # requests before submitting, and `PaperApplicationService` deciding whether it may write. If each
  # built its own detection call, hard-block interpretation, candidate list, or decision token, a
  # preview could show one thing and the writer conclude another -- which is the class of drift this
  # slice exists to remove. So this object owns all of it, and the writer consumes the result rather
  # than re-deriving any part of it.
  #
  # The contact flags are the easiest part to get wrong. `PaperContactFlags#apply_to` *changes the
  # facts before detection*: choosing "no email" deletes the email and switches the communication
  # preference. A preview that skipped the flags would sign a different fact set than the writer
  # verifies, and every confirmation would fail for no reason staff could see.
  #
  # Read-only by construction. It detects, describes, verifies and signs; nothing here writes.
  class PaperIdentityReview
    CONTEXTS = {
      self_applicant: { detection: :paper_new_self, contact_scope: :constituent },
      guardian: { detection: :paper_new_guardian, contact_scope: :guardian },
      dependent: { detection: :paper_new_dependent, contact_scope: nil }
    }.freeze

    # `candidates` is what the search surfaced. `selectable_candidates` is the subset staff can
    # actually act on: an exact email or phone collision may belong to a record that cannot be a
    # paper applicant at all, and telling staff to "select the existing applicant" is useless when
    # the matched record is not selectable. The endpoint needs both, plus `reasons`, to say anything
    # actionable.
    # Keyword-only deliberately: `candidates`, `selectable_candidates` and `reasons` are three
    # adjacent collections, and a positional transposition between them would produce a result that
    # looks right and tells the endpoint something false.
    # rubocop:disable Style/RedundantStructKeywordInit -- not redundant: a plain Struct still accepts
    # positional construction, which is the transposition this is here to make impossible.
    Result = Struct.new(:state, :candidates, :selectable_candidates, :presented_candidates,
                        :reasons, :token, :decision_reason, :identity_facts, keyword_init: true) do
      def blocked? = state == :blocked
      def clear? = state == :clear
      def confirmed? = state == :confirmed
      def needs_confirmation? = state == :needs_confirmation
      def error? = state == :error
      def invalid_decision? = state == :invalid_decision
      def candidate_ids = Array(candidates).map(&:id)

      # Creation may proceed either because the search turned nothing up or because staff looked at
      # what it did turn up and said those are different people.
      def permits_creation? = clear? || confirmed?
    end
    # rubocop:enable Style/RedundantStructKeywordInit

    # @param submitted_token [String, nil] the decision the request carried, if any. The preview
    #   passes nothing; the writer passes what staff returned.
    def initialize(constituent_params:, admin:, contact_flag_params: nil, submitted_token: nil,
                   context: :self_applicant, context_data: {})
      @constituent_params = constituent_params
      @admin = admin
      @contact_flag_params = contact_flag_params || constituent_params
      @submitted_token = submitted_token
      @context = context.to_sym
      @context_config = CONTEXTS.fetch(@context)
      @guardian = context_data[:guardian]
      @relationship_type = context_data[:relationship_type]
    end

    def call
      detection = detect
      if detection.blank?
        return Result.new(state: :error, candidates: [], selectable_candidates: [],
                          presented_candidates: [], reasons: [],
                          token: nil, decision_reason: nil, identity_facts: identity_facts)
      end

      candidates = Array(detection.matched_users)
      reasons = Array(detection.reasons)
      return blocked_result(candidates, reasons) if detection.hard_block

      confirmed_or_pending(candidates, reasons)
    end

    # The exact rows the browser renders. Owned here, not in the controller, for the same reason
    # detection is: a decision is signed over what staff were shown, so if presentation lived on the
    # endpoint side then the write boundary would be verifying a snapshot it never built.
    #
    # Enough for staff to tell two people apart, and no more. Contact details are deliberately
    # excluded: a soft match is decided on identity, and an exact-contact conflict is described by
    # its reason codes rather than by echoing the other record's email or phone back to the browser.
    def presented_candidates(candidates, selectable_candidates: selectable(candidates))
      selectable_ids = selectable_candidates.to_set(&:id)
      Array(candidates).map do |candidate|
        {
          id: candidate.id,
          name: candidate.full_name,
          date_of_birth: candidate.date_of_birth&.to_fs(:long),
          city: candidate.city,
          state: candidate.state,
          zip_code: candidate.zip_code,
          selectable: selectable_ids.include?(candidate.id)
        }
      end
    end

    # The exact fact set detection sees, which is also the fact set a decision is signed over.
    def identity_facts
      @identity_facts ||= self.class.detection_facts(applicant_data)
    end

    # Canonical detection facts. Owned here rather than in the writer so the preview and the write
    # boundary cannot disagree about what "the same applicant" means. Email, phone and date of birth
    # are canonicalized; names, address lines, city, state and ZIP pass through as submitted and are
    # therefore compared strictly.
    def self.detection_facts(attrs)
      data = if attrs.respond_to?(:to_unsafe_h)
               attrs.to_unsafe_h.with_indifferent_access
             else
               attrs.to_h.with_indifferent_access
             end
      dob_holder = Users::Constituent.new
      dob_holder.date_of_birth = data[:date_of_birth] if data.key?(:date_of_birth)

      {
        email: User.normalize_email(data[:email]),
        phone: User.normalize_phone(data[:phone]),
        first_name: data[:first_name],
        last_name: data[:last_name],
        date_of_birth: dob_holder.date_of_birth,
        physical_address_1: data[:physical_address_1],
        physical_address_2: data[:physical_address_2],
        city: data[:city],
        state: data[:state],
        zip_code: data[:zip_code]
      }
    end

    private

    def detect
      result = DuplicateDetectionService.new(context: @context_config.fetch(:detection), attrs: identity_facts).call
      return result.data if result.success?

      nil
    end

    # Flags applied first, exactly as the writer applies them, so preview and verification agree.
    def applicant_data
      return dependent_applicant_data if @context == :dependent

      PaperContactFlags.new(
        @contact_flag_params,
        scope: @context_config.fetch(:contact_scope)
      ).apply_to(@constituent_params)
    end

    # A hard block is not a decision staff may take, so no token is issued: there is nothing to
    # present, replay, or acknowledge away. The reasons are preserved -- exact_email, exact_phone, a
    # split-contact conflict -- because they are the only thing that lets the endpoint explain what
    # happened, particularly when the matched record is not selectable.
    def blocked_result(candidates, reasons)
      blocked_selectable = reasons.include?('email_phone_split') ? [] : selectable(candidates)
      Result.new(state: :blocked, candidates: candidates,
                 selectable_candidates: blocked_selectable,
                 presented_candidates: presented_candidates(candidates, selectable_candidates: blocked_selectable), reasons: reasons,
                 token: nil, decision_reason: nil, identity_facts: identity_facts)
    end

    # Nothing surfaced, so there is nothing for staff to decide. Requiring a click here would be
    # friction that proves nothing: it is the server's search -- run against the completed applicant
    # immediately before the write -- that establishes no match, not a second confirmation of it.
    # A decision is only meaningful when staff are overriding something the computer surfaced.
    def confirmed_or_pending(candidates, reasons)
      if candidates.empty?
        if @submitted_token.present?
          facts = PaperIdentityDecision::Facts.new(decision_context, @admin, identity_facts, [], reasons)
          decision = PaperIdentityDecision.verify(@submitted_token, facts)
          return Result.new(state: :invalid_decision, candidates: [], selectable_candidates: [],
                            presented_candidates: [], reasons: reasons,
                            token: nil, decision_reason: decision.reason, identity_facts: identity_facts)
        end

        return Result.new(state: :clear, candidates: [], selectable_candidates: [],
                          presented_candidates: [], reasons: reasons,
                          token: nil, decision_reason: nil, identity_facts: identity_facts)
      end

      presented = presented_candidates(candidates)
      facts = PaperIdentityDecision::Facts.new(decision_context, @admin, identity_facts,
                                               presented, reasons)
      decision = PaperIdentityDecision.verify(@submitted_token, facts)

      if decision.valid?
        Result.new(state: :confirmed, candidates: candidates,
                   selectable_candidates: selectable(candidates), presented_candidates: presented,
                   reasons: reasons, token: nil, decision_reason: nil, identity_facts: identity_facts)
      else
        Result.new(state: :needs_confirmation, candidates: candidates,
                   selectable_candidates: selectable(candidates), presented_candidates: presented,
                   reasons: reasons, token: PaperIdentityDecision.issue(facts),
                   decision_reason: decision.reason, identity_facts: identity_facts)
      end
    end

    def selectable(candidates)
      candidates.select { |candidate| candidate_selectable?(candidate) }
    end

    def candidate_selectable?(candidate)
      case @context
      when :guardian
        candidate.respond_to?(:paper_guardian_candidate?) && candidate.paper_guardian_candidate?
      when :dependent
        candidate.respond_to?(:paper_dependent_candidate?) && candidate.paper_dependent_candidate? &&
          paper_application_eligible?(candidate) && guardian_relationship_exists?(candidate)
      else
        candidate.respond_to?(:paper_applicant_candidate?) && candidate.paper_applicant_candidate?
      end
    end

    def paper_application_eligible?(candidate)
      return false if candidate.applications.blocking_new_submission.exists?

      last_application = candidate.applications.order(application_date: :desc).first
      return true if last_application.blank?

      waiting_period = Policy.get('waiting_period_years') || 3
      last_application.application_date + waiting_period.years <= Time.current
    end

    # Paper intake may choose an on-file dependent already owned by the selected guardian. Creating
    # a new guardian relationship is a separate identity-authority decision and is not inferred from
    # a raw candidate id or a demographic match.
    def guardian_relationship_exists?(candidate)
      return false if @guardian.blank?

      GuardianRelationship.exists?(guardian_id: @guardian.id, dependent_id: candidate.id)
    end

    # Random synthetic credentials are created later and cannot be signed review facts. Guardian
    # contact is absent from dependent identity matching; guardian address is a deterministic copy.
    def dependent_applicant_data
      data = hash_for(@constituent_params).deep_dup.with_indifferent_access
      choices = hash_for(@contact_flag_params).with_indifferent_access

      if choices[:email_strategy].to_s == 'guardian'
        data.delete(:email)
      elsif data[:dependent_email].present?
        data[:email] = data[:dependent_email]
      end

      if choices[:phone_strategy].to_s == 'guardian'
        data.delete(:phone)
      elsif data[:dependent_phone].present?
        data[:phone] = data[:dependent_phone]
      end

      if choices[:address_strategy].to_s == 'guardian' && @guardian.present?
        %i[physical_address_1 physical_address_2 city state zip_code].each do |field|
          data[field] = @guardian.public_send(field)
        end
      end
      data
    end

    def decision_context
      return @context unless @context == :dependent

      "dependent:guardian=#{@guardian&.id}:relationship=#{@relationship_type}"
    end

    def hash_for(value)
      return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)

      value.to_h
    end
  end
end
