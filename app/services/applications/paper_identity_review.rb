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
      def candidate_ids = Array(candidates).map(&:id)

      # Creation may proceed either because the search turned nothing up or because staff looked at
      # what it did turn up and said those are different people.
      def permits_creation? = clear? || confirmed?
    end
    # rubocop:enable Style/RedundantStructKeywordInit

    # @param submitted_token [String, nil] the decision the request carried, if any. The preview
    #   passes nothing; the writer passes what staff returned.
    def initialize(constituent_params:, admin:, contact_flag_params: nil, submitted_token: nil)
      @constituent_params = constituent_params
      @admin = admin
      @contact_flag_params = contact_flag_params || constituent_params
      @submitted_token = submitted_token
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
    def presented_candidates(candidates)
      selectable_ids = selectable(candidates).to_set(&:id)
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
      result = DuplicateDetectionService.new(context: :paper_new_self, attrs: identity_facts).call
      return result.data if result.success?

      nil
    end

    # Flags applied first, exactly as the writer applies them, so preview and verification agree.
    def applicant_data
      PaperContactFlags.new(@contact_flag_params, scope: :constituent).apply_to(@constituent_params)
    end

    # A hard block is not a decision staff may take, so no token is issued: there is nothing to
    # present, replay, or acknowledge away. The reasons are preserved -- exact_email, exact_phone, a
    # split-contact conflict -- because they are the only thing that lets the endpoint explain what
    # happened, particularly when the matched record is not selectable.
    def blocked_result(candidates, reasons)
      Result.new(state: :blocked, candidates: candidates,
                 selectable_candidates: selectable(candidates),
                 presented_candidates: presented_candidates(candidates), reasons: reasons,
                 token: nil, decision_reason: nil, identity_facts: identity_facts)
    end

    # Nothing surfaced, so there is nothing for staff to decide. Requiring a click here would be
    # friction that proves nothing: it is the server's search -- run against the completed applicant
    # immediately before the write -- that establishes no match, not a second confirmation of it.
    # A decision is only meaningful when staff are overriding something the computer surfaced.
    def confirmed_or_pending(candidates, reasons)
      if candidates.empty?
        return Result.new(state: :clear, candidates: [], selectable_candidates: [],
                          presented_candidates: [], reasons: reasons,
                          token: nil, decision_reason: nil, identity_facts: identity_facts)
      end

      presented = presented_candidates(candidates)
      facts = PaperIdentityDecision::Facts.new(:self_applicant, @admin, identity_facts,
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
      candidates.select { |user| user.respond_to?(:paper_applicant_candidate?) && user.paper_applicant_candidate? }
    end
  end
end
