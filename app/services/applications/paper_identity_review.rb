# frozen_string_literal: true

module Applications
  # Normalizes and rechecks the paper identity shown in a server-rendered review.
  class PaperIdentityReview
    CONTEXTS = {
      self_applicant: { detection: :paper_new_self, contact_scope: :constituent },
      guardian: { detection: :paper_new_guardian, contact_scope: :guardian },
      dependent: { detection: :paper_new_dependent, contact_scope: nil }
    }.freeze

    Result = Struct.new(:state, :candidates, :selectable_candidates, :presented_candidates,
                        :reasons, :token, :decision_reason, :identity_facts, :context, :selected_user) do
      def blocked? = state == :blocked
      def clear? = state == :clear
      def confirmed? = state == :confirmed
      def selected? = state == :selected
      def needs_confirmation? = state == :needs_confirmation
      def error? = state == :error
      def invalid_decision? = state == :invalid_decision
      def candidate_ids = Array(candidates).map(&:id)
      def permits_creation? = clear? || confirmed?
    end

    # rubocop:disable Metrics/ParameterLists -- identity facts, actor, context and explicit decision share one boundary
    def initialize(constituent_params:, admin:, contact_flag_params: nil, submitted_token: nil,
                   context: :self_applicant, context_data: {}, selected_candidate_id: nil, determination: nil)
      @constituent_params = constituent_params
      @admin = admin
      @contact_flag_params = contact_flag_params || constituent_params
      @submitted_token = submitted_token
      @context = context.to_sym
      @context_config = CONTEXTS.fetch(@context)
      @guardian = context_data[:guardian]
      @relationship_type = context_data[:relationship_type]
      @selected_candidate_id = selected_candidate_id
      @determination = determination
    end

    # rubocop:enable Metrics/ParameterLists

    def call(lock: false)
      detection = detect
      return result(:error) unless detection

      detection = locked_detection(detection) if lock
      return result(:error) unless detection

      candidates = detection.matched_users
      allowed = detection.reasons.include?('email_phone_split') ? [] : selectable(candidates)
      presented = presented_candidates(candidates, selectable_candidates: allowed)
      facts = PaperIdentityReviewReceipt::Facts.new(decision_context, @admin, identity_facts, presented, detection.reasons)
      valid = PaperIdentityReviewReceipt.verify(@submitted_token, facts).valid?
      selected = allowed.find { |user| user.id.to_s == @selected_candidate_id.to_s }
      state = decision_state(detection, selected, valid)
      result(state, candidates: candidates, selectable_candidates: allowed, presented_candidates: presented,
                    reasons: detection.reasons, selected_user: state == :selected ? selected : nil,
                    token: candidates.any? ? PaperIdentityReviewReceipt.issue(facts) : nil,
                    decision_reason: @submitted_token.present? && !valid ? :mismatched : nil)
    end

    def identity_facts
      @identity_facts ||= self.class.detection_facts(applicant_data)
    end

    def presented_candidates(candidates, selectable_candidates: selectable(candidates))
      selectable_ids = selectable_candidates.map(&:id)
      candidates.map do |candidate|
        { id: candidate.id, name: candidate.full_name, date_of_birth: candidate.date_of_birth&.to_fs(:long),
          city: candidate.city, state: candidate.state, zip_code: candidate.zip_code,
          selectable: selectable_ids.include?(candidate.id) }
      end
    end

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

    def locked_detection(detection)
      return unless @admin&.persisted?

      participants = [@admin, @guardian, *detection.matched_users].compact
      locked = User.lock_for_merge_integrity!(*participants)
      @admin = locked.fetch(@admin.id)
      @guardian = locked.fetch(@guardian.id) if @guardian
      @identity_facts = nil
      return unless @admin.admin? && @admin.public_login_active?
      return if @context == :dependent && !@guardian&.paper_guardian_candidate?

      refreshed = detect
      return unless refreshed

      if (refreshed.matched_users.map(&:id) - locked.keys).any?
        # A new candidate requires a new review, without taking locks out of order.
        @submitted_token = @selected_candidate_id = @determination = nil
      end
      refreshed
    end

    def decision_state(detection, selected, valid)
      return :selected if selected && valid
      return :blocked if detection.hard_block
      return :invalid_decision if @selected_candidate_id.present? || (@submitted_token.present? && !valid)
      return :clear if detection.matched_users.empty? && @submitted_token.blank?
      return :invalid_decision if detection.matched_users.empty?
      return :confirmed if valid && @determination == 'keep_separate'

      :needs_confirmation
    end

    def result(state, **attributes)
      Result.new(state: state, candidates: [], selectable_candidates: [], presented_candidates: [],
                 reasons: [], identity_facts: identity_facts, context: @context, **attributes)
    end

    def detect
      detection = DuplicateDetectionService.new(context: @context_config.fetch(:detection), attrs: identity_facts).call
      detection.data if detection.success?
    end

    def applicant_data
      return dependent_applicant_data if @context == :dependent

      PaperContactFlags.new(
        @contact_flag_params,
        scope: @context_config.fetch(:contact_scope)
      ).apply_to(@constituent_params)
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
          PaperApplicationEligibility.call(candidate).eligible? && guardian_relationship_exists?(candidate)
      else
        candidate.respond_to?(:paper_applicant_candidate?) && candidate.paper_applicant_candidate? &&
          PaperApplicationEligibility.call(candidate).eligible?
      end
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
