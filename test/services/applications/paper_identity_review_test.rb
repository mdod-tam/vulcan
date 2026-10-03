# frozen_string_literal: true

require 'test_helper'

module Applications
  # The admin form runs this review before submit. PaperApplicationService runs it again at write time.
  # The two results must agree, so most of these tests pin parity, not preview-only behavior.
  class PaperIdentityReviewTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @facts = { first_name: 'Review', last_name: 'Subject', date_of_birth: '04/02/1990',
                 email: "review-#{SecureRandom.hex(4)}@example.com", phone: '555-000-0123',
                 physical_address_1: '5 Review Way', city: 'Baltimore', state: 'MD', zip_code: '21201' }
    end

    # With no match, staff have no decision to make and the review signs nothing.
    test 'an applicant with nothing matching is clear to create with no token' do
      result = review(@facts)

      assert result.clear?, "expected a clear review, got #{result.state}"
      assert result.permits_creation?
      assert_empty result.candidates
      assert_nil result.token
    end

    test 'a name and date of birth match reports the candidate and why' do
      existing = create(:constituent, first_name: 'Review', last_name: 'Subject',
                                      date_of_birth: Date.new(1990, 4, 2))

      result = review(@facts)

      assert result.needs_confirmation?, "expected a decide-between review, got #{result.state}"
      assert_not result.permits_creation?
      assert result.token.present?
      assert_equal [existing.id], result.candidates.map(&:id)
      assert_includes result.reasons, 'name_dob'
    end

    # Staff cannot override a hard block. The receipt supports only selection of a record.
    test 'an exact contact collision issues a receipt for selection only' do
      existing = create(:constituent, email: "collide-#{SecureRandom.hex(3)}@example.com")

      result = review(@facts.merge(email: existing.email))

      assert result.blocked?
      assert result.token.present?
      assert_not review_object(@facts.merge(email: existing.email), submitted_token: result.token, determination: 'keep_separate').call.permits_creation?
    end

    # The endpoint needs the reasons to explain a refusal. It needs selectable_candidates to show
    # whether "use the existing record" is available.
    test 'a blocked result keeps the reasons that explain the refusal' do
      existing = create(:constituent, email: "collide-#{SecureRandom.hex(3)}@example.com")

      result = review(@facts.merge(email: existing.email))

      assert_includes result.reasons, 'exact_email'
      assert_equal [existing.id], result.candidates.map(&:id)
    end

    test 'a blocked constituent is offered as selectable' do
      existing = create(:constituent, phone: '555-000-4321')

      result = review(@facts.merge(phone: existing.phone))

      assert result.blocked?
      assert_equal [existing.id], result.selectable_candidates.map(&:id)
    end

    # A match that cannot be a paper applicant explains the block, but it is not a choice.
    test 'a blocked non-constituent is reported but not selectable' do
      admin_match = create(:admin, email: "admin-collide-#{SecureRandom.hex(3)}@example.com")

      result = review(@facts.merge(email: admin_match.email))

      assert result.blocked?
      assert_includes result.candidates.map(&:id), admin_match.id
      assert_empty result.selectable_candidates
    end

    # A merged record stays a Constituent, so a type check alone offers it.
    # A new application on that record attaches to an account that the merge retired.
    test 'a retired merged record is reported but never selectable' do
      survivor = create(:constituent)
      retired = create(:constituent, phone: '555-000-7654', merged_into_user: survivor)

      result = review(@facts.merge(phone: retired.phone))

      assert result.blocked?
      assert_includes result.candidates.map(&:id), retired.id, 'staff still need to see why they are blocked'
      assert_empty result.selectable_candidates, 'a retired record must not be offered as an applicant'
    end

    # The decision signs the presented rows, so each row carries `selectable`.
    # The panel and the signature must agree about which rows staff can select.
    test 'the presented snapshot reports the selectable state of each row' do
      survivor = create(:constituent)
      retired = create(:constituent, first_name: 'Review', last_name: 'Subject',
                                     date_of_birth: Date.new(1990, 4, 2), merged_into_user: survivor)

      row = review(@facts).presented_candidates.find { |candidate| candidate[:id] == retired.id }

      assert_not_nil row, 'the retired record must still be presented'
      assert_not row[:selectable]
    end

    # In a split conflict, one record has the email and a different record has the phone.
    # The endpoint needs both records and both reasons to describe the conflict.
    test 'a split email and phone conflict preserves both records and both reasons' do
      email_owner = create(:constituent, email: "split-email-#{SecureRandom.hex(3)}@example.com")
      phone_owner = create(:constituent, phone: '555-000-8765')

      result = review(@facts.merge(email: email_owner.email, phone: phone_owner.phone))

      assert result.blocked?
      assert_equal [email_owner.id, phone_owner.id].sort, result.candidates.map(&:id).sort
      assert_includes result.reasons, 'email_phone_split'
      assert_empty result.selectable_candidates,
                   'selecting either record cannot resolve contact owned by the other record'
      assert(result.presented_candidates.none? { |candidate| candidate[:selectable] })
    end

    # PaperContactFlags removes the email for "no email" before detection.
    # Without the flags, the preview signs different facts than the writer.
    test 'contact flags are applied before detection, as the writer applies them' do
      flagged = review_object(@facts, contact_flag_params: @facts.merge(no_email_address: '1'))

      assert_nil flagged.identity_facts[:email]
      assert_not_equal review_object(@facts).identity_facts, flagged.identity_facts
    end

    # End-to-end parity: PaperApplicationService must accept this token for the same params.
    # A token needs a soft match. The no-contact flag is the most likely parity break because it
    # changes the facts before detection and is outside the constituent hash.
    test 'a token issued here is accepted by the writer, no-contact flag included' do
      create(:constituent, first_name: 'Parity', last_name: 'Case', date_of_birth: Date.new(1990, 4, 2))
      params = writer_params(no_email_address: '1')
      preview = preview_for(params)

      assert preview.needs_confirmation?, "expected a decision to be required, got #{preview.state}"

      service = Applications::PaperApplicationService.new(
        params: params.merge(identity_determination: 'keep_separate', identity_rationale: 'Staff confirmed different people.', identity_review_receipt: preview.token), admin: @admin, skip_proof_processing: true
      )

      assert service.create, "the writer rejected a token this review issued: #{service.errors.inspect}"
    end

    test 'removing the no-contact flag after review invalidates the token' do
      create(:constituent, first_name: 'Parity', last_name: 'Case', date_of_birth: Date.new(1990, 4, 2))
      params = writer_params(no_email_address: '1')
      preview = preview_for(params)

      # Without the flag, detection sees an email that the signed facts do not include.
      service = Applications::PaperApplicationService.new(
        params: params.except(:no_email_address).merge(identity_determination: 'keep_separate', identity_rationale: 'Staff confirmed different people.', identity_review_receipt: preview.token),
        admin: @admin, skip_proof_processing: true
      )

      assert_not service.create
      assert_match(/changed since you reviewed them/i, service.errors.join(' '))
    end

    test 'a submitted decision is not ignored when edited facts now have no candidates' do
      create(:constituent, first_name: 'Review', last_name: 'Subject', date_of_birth: Date.new(1990, 4, 2))
      preview = review(@facts)
      assert preview.needs_confirmation?

      changed = review_object(@facts.merge(last_name: 'Different'), contact_flag_params: @facts,
                                                                    submitted_token: preview.token).call

      assert changed.invalid_decision?
      assert_not changed.permits_creation?
      assert_equal :mismatched, changed.decision_reason
      assert_empty changed.candidates
    end

    test 'dependent decisions recheck guardian address after acquiring current rows' do
      guardian = create(:constituent)
      create(:constituent, first_name: 'Review', last_name: 'Subject', date_of_birth: Date.new(1990, 4, 2))
      options = { constituent_params: @facts, admin: @admin, context: :dependent,
                  contact_flag_params: { address_strategy: 'guardian' },
                  context_data: { guardian: guardian, relationship_type: 'Parent' } }
      receipt = PaperIdentityReview.new(**options).call.token
      review = PaperIdentityReview.new(**options, submitted_token: receipt, determination: 'keep_separate')
      review.identity_facts
      User.find(guardian.id).update!(city: 'Changed after the form loaded')

      assert review.call(lock: true).invalid_decision?
    end

    test 'dependent selection requires a current relationship and application eligibility' do
      guardian = create(:constituent)
      candidate = create(:constituent, first_name: 'Review', last_name: 'Subject', date_of_birth: Date.new(1990, 4, 2))
      options = { constituent_params: @facts, admin: @admin, context: :dependent,
                  context_data: { guardian: guardian, relationship_type: 'Parent' } }
      assert_empty PaperIdentityReview.new(**options).call.selectable_candidates
      relationship = create(:guardian_relationship, guardian_id: guardian.id, dependent_id: candidate.id)
      initial = PaperIdentityReview.new(**options).call
      assert_includes initial.selectable_candidates, candidate
      choice = { submitted_token: initial.token, selected_candidate_id: candidate.id }
      assert PaperIdentityReview.new(**options, **choice).call(lock: true).selected?
      relationship.destroy!
      assert_not PaperIdentityReview.new(**options, **choice).call(lock: true).selected?
    end

    private

    def preview_for(params)
      PaperIdentityReview.new(constituent_params: params[:constituent], admin: @admin,
                              contact_flag_params: params).call
    end

    # A complete paper submission, so the writer does not fail early for an unrelated reason.
    def writer_params(**extra)
      {
        constituent: @facts.merge(first_name: 'Parity', last_name: 'Case',
                                  date_of_birth: '04/02/1990', hearing_disability: '1',
                                  email: "parity-#{SecureRandom.hex(4)}@example.com"),
        application: { household_size: '2', annual_income: '15000', maryland_resident: '1',
                       self_certify_disability: '1', medical_provider_name: 'Dr. Parity',
                       medical_provider_phone: '2025559876',
                       medical_provider_email: 'parity@example.com' }
      }.merge(extra)
    end

    def review_object(facts, contact_flag_params: nil, submitted_token: nil, determination: nil)
      PaperIdentityReview.new(constituent_params: facts, admin: @admin,
                              contact_flag_params: contact_flag_params, submitted_token: submitted_token,
                              determination: determination)
    end

    def review(facts, contact_flag_params: nil)
      review_object(facts, contact_flag_params: contact_flag_params).call
    end
  end
end
