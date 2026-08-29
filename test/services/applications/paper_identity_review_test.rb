# frozen_string_literal: true

require 'test_helper'

module Applications
  # The review is what the admin form asks before submitting; PaperApplicationService recomputes the
  # same thing at the write boundary. These two must never disagree, so the properties pinned here
  # are mostly parity properties rather than behaviour unique to the preview.
  class PaperIdentityReviewTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @facts = { first_name: 'Review', last_name: 'Subject', date_of_birth: '04/02/1990',
                 email: "review-#{SecureRandom.hex(4)}@example.com", phone: '555-000-0123',
                 physical_address_1: '5 Review Way', city: 'Baltimore', state: 'MD', zip_code: '21201' }
    end

    # Nothing surfaced, so there is nothing to decide and nothing to sign. Asking staff to confirm
    # here would be friction that proves nothing the server's own search has not established.
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
      assert_match(/\Av1:\d+:[a-f0-9]{64}\z/, result.token)
      assert_equal [existing.id], result.candidates.map(&:id)
      assert_includes result.reasons, 'name_dob'
    end

    # A hard block is not a decision staff may take, so there must be nothing to acknowledge away.
    test 'an exact contact collision is blocked and issues no token' do
      existing = create(:constituent, email: "collide-#{SecureRandom.hex(3)}@example.com")

      result = review(@facts.merge(email: existing.email))

      assert result.blocked?
      assert_nil result.token
    end

    # The endpoint depends on these fields to say anything useful, so they are pinned here rather
    # than only where the endpoint is tested. Without the reasons it cannot explain *why* the
    # applicant was refused; without the selectable split it cannot tell staff whether "use the
    # existing record" is even an available action.
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

    # "Select the existing applicant" is not an action when the matched record cannot be a paper
    # applicant. Such a match must still be reported -- staff need to know why they are blocked --
    # but it must not be presented as a choice.
    test 'a blocked non-constituent is reported but not selectable' do
      admin_match = create(:admin, email: "admin-collide-#{SecureRandom.hex(3)}@example.com")

      result = review(@facts.merge(email: admin_match.email))

      assert result.blocked?
      assert_includes result.candidates.map(&:id), admin_match.id
      assert_empty result.selectable_candidates
    end

    # A merge retires the duplicate by pointing it at a survivor but leaves it a Constituent, so the
    # type check alone kept offering it. Attaching a new application to a retired record hangs that
    # application off the very record the merge declared is not the person.
    test 'a retired merged record is reported but never selectable' do
      survivor = create(:constituent)
      retired = create(:constituent, phone: '555-000-7654', merged_into_user: survivor)

      result = review(@facts.merge(phone: retired.phone))

      assert result.blocked?
      assert_includes result.candidates.map(&:id), retired.id, 'staff still need to see why they are blocked'
      assert_empty result.selectable_candidates, 'a retired record must not be offered as an applicant'
    end

    # The presented snapshot is what the decision is signed over, so `selectable` has to travel with
    # it -- the panel and the signature must agree about which rows could be picked.
    test 'the presented snapshot reports the selectable state of each row' do
      survivor = create(:constituent)
      retired = create(:constituent, first_name: 'Review', last_name: 'Subject',
                                     date_of_birth: Date.new(1990, 4, 2), merged_into_user: survivor)

      row = review(@facts).presented_candidates.find { |candidate| candidate[:id] == retired.id }

      assert_not_nil row, 'the retired record must still be presented'
      assert_not row[:selectable]
    end

    # A split conflict is two different records, one holding the email and one the phone. Both must
    # survive, and so must both reasons, or the endpoint cannot describe the situation at all.
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

    # PaperContactFlags rewrites the facts before detection: choosing "no email" removes the email
    # entirely. A preview that ignored the flags would sign a different fact set than the writer.
    test 'contact flags are applied before detection, as the writer applies them' do
      flagged = review_object(@facts, contact_flag_params: @facts.merge(no_email_address: '1'))

      assert_nil flagged.identity_facts[:email]
      assert_not_equal review_object(@facts).identity_facts, flagged.identity_facts
    end

    # The real parity property, exercised end to end rather than by comparing the review to itself:
    # a token this object issues must be accepted by PaperApplicationService for the same params.
    # A soft match is required for a token to exist at all, and the no-contact flag is the case most
    # likely to break parity, because it changes the facts before detection and lives outside the
    # constituent hash.
    test 'a token issued here is accepted by the writer, no-contact flag included' do
      create(:constituent, first_name: 'Parity', last_name: 'Case', date_of_birth: Date.new(1990, 4, 2))
      params = writer_params(no_email_address: '1')
      preview = preview_for(params)

      assert preview.needs_confirmation?, "expected a decision to be required, got #{preview.state}"

      service = Applications::PaperApplicationService.new(
        params: params.merge(identity_decision: preview.token), admin: @admin, skip_proof_processing: true
      )

      assert service.create, "the writer rejected a token this review issued: #{service.errors.inspect}"
    end

    test 'removing the no-contact flag after review invalidates the token' do
      create(:constituent, first_name: 'Parity', last_name: 'Case', date_of_birth: Date.new(1990, 4, 2))
      params = writer_params(no_email_address: '1')
      preview = preview_for(params)

      # Same constituent hash, flag dropped: detection now sees an email it did not see before, so
      # the facts the token was signed over no longer describe this submission.
      service = Applications::PaperApplicationService.new(
        params: params.except(:no_email_address).merge(identity_decision: preview.token),
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

    private

    # A complete paper submission, so the writer can actually run rather than fail earlier for
    # unrelated reasons.
    def preview_for(params)
      PaperIdentityReview.new(constituent_params: params[:constituent], admin: @admin,
                              contact_flag_params: params).call
    end

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

    def review_object(facts, contact_flag_params: nil, submitted_token: nil)
      PaperIdentityReview.new(constituent_params: facts, admin: @admin,
                              contact_flag_params: contact_flag_params, submitted_token: submitted_token)
    end

    def review(facts, contact_flag_params: nil)
      review_object(facts, contact_flag_params: contact_flag_params).call
    end
  end
end
