# frozen_string_literal: true

require 'test_helper'

module Applications
  # A decision that survives an identity change moves a review from one applicant to another.
  # These tests pin what invalidates a decision.
  class PaperIdentityReviewReceiptTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @other_admin = create(:admin)
      # The caller's duplicate_detection_attrs canonicalizes these facts. The receipt does not
      # normalize them again, so only one definition of "the same facts" exists.
      @identity = { first_name: 'John', last_name: 'Smith', date_of_birth: Date.new(1990, 4, 2),
                    email: 'john.smith@example.com', phone: '5555550100',
                    physical_address_1: '1 Main St', physical_address_2: nil,
                    city: 'Baltimore', state: 'MD', zip_code: '21201' }
      # The rows the browser showed, not only their ids.
      @candidates = [
        { id: 11, name: 'John Smith', date_of_birth: 'April 2, 1990',
          city: 'Baltimore', state: 'MD', zip_code: '21201', selectable: true },
        { id: 7, name: 'Jon Smith', date_of_birth: 'April 2, 1990',
          city: 'Annapolis', state: 'MD', zip_code: '21401', selectable: true },
        { id: 3, name: 'J Smith', date_of_birth: 'April 2, 1990',
          city: 'Bethesda', state: 'MD', zip_code: '20814', selectable: false }
      ]
      @reasons = %w[name_dob address_zip]
    end

    test 'a freshly issued decision verifies' do
      assert verify(issue).valid?
    end

    # A search for John followed by a submission for Jane must not verify.
    # Each value differs materially. Caller canonicalization can absorb a suffix on a date or phone.
    {
      first_name: 'Jane',
      last_name: 'Smythe',
      date_of_birth: Date.new(1991, 4, 2),
      email: 'someone.else@example.com',
      phone: '5555559999',
      physical_address_1: '2 Other Ave',
      physical_address_2: 'Apt 4',
      city: 'Annapolis',
      state: 'VA',
      zip_code: '21401'
    }.each do |field, changed_value|
      test "a changed #{field} invalidates the decision" do
        token = issue
        result = verify(token, identity: @identity.merge(field => changed_value))

        assert_not result.valid?
        assert_equal :mismatched, result.reason
      end
    end

    # Detection scores the address, so the decision binds it. A change between two non-matching
    # addresses keeps the candidate ids and reasons the same.
    # An absent second address line and a cleared one are different submissions.
    # If the fingerprint made every value a string, one could replace the other.
    test 'a blank value is not the same fact as a missing one' do
      # The token embeds its expiry. Two tokens issued in different seconds always differ,
      # so both use one instant.
      at = Time.current
      assert_not_equal issue(identity: @identity.merge(physical_address_2: nil), issued_at: at),
                       issue(identity: @identity.merge(physical_address_2: ''), issued_at: at)
    end

    test 'a decision issued for a missing value does not verify against a blank one' do
      token = issue(identity: @identity.merge(physical_address_2: nil))

      assert_not verify(token, identity: @identity.merge(physical_address_2: '')).valid?
    end

    test 'key order does not change the identity' do
      shuffled = @identity.to_a.reverse.to_h
      assert verify(issue(identity: shuffled)).valid?
    end

    # The set can change because a record was created between steps or the request supplied a list.
    test 'a changed candidate set invalidates the decision' do
      token = issue
      newcomer = { id: 99, name: 'Jane Smith', date_of_birth: 'April 2, 1990',
                   city: 'Baltimore', state: 'MD', zip_code: '21201', selectable: true }
      result = verify(token, candidates: @candidates + [newcomer])

      assert_not result.valid?
      assert_equal :mismatched, result.reason
    end

    # Staff decide on the text of each row. Each change keeps the candidate ids and reason codes.
    {
      name: 'Jonathan Smith',
      date_of_birth: 'April 3, 1990',
      city: 'Rockville',
      state: 'VA',
      zip_code: '21299'
    }.each do |field, changed_value|
      test "a changed displayed #{field} invalidates the decision" do
        token = issue
        shown = @candidates.map(&:dup)
        shown[0][field] = changed_value
        result = verify(token, candidates: shown)

        assert_not result.valid?, "#{field} changed on screen but the decision still verified"
        assert_equal :mismatched, result.reason
      end
    end

    # "These are different people" has a different meaning when staff could not select the row.
    test 'a changed selectable state invalidates the decision' do
      token = issue
      shown = @candidates.map(&:dup)
      shown[2][:selectable] = true

      assert_not verify(token, candidates: shown).valid?
    end

    test 'candidate and reason ordering does not change the decision' do
      token = issue(candidates: @candidates.reverse, reasons: %w[address_zip name_dob])
      assert verify(token, candidates: @candidates, reasons: %w[name_dob address_zip]).valid?
    end

    test 'candidate key order does not change the decision' do
      shuffled = @candidates.map { |candidate| candidate.to_a.reverse.to_h }
      assert verify(issue(candidates: shuffled)).valid?
    end

    test 'a changed match reason invalidates the decision' do
      assert_not verify(issue, reasons: %w[name_dob]).valid?
    end

    # A decision is the attestation of one admin.
    test 'another admin cannot use this decision' do
      assert_not verify(issue, admin: @other_admin).valid?
    end

    test 'the decision context is bound' do
      assert_not verify(issue(context: :self_applicant), context: :dependent).valid?
    end

    # An old form must not authorize a creation, even when the identity did not change.
    test 'a decision expires' do
      token = issue(issued_at: 2.hours.ago)
      result = verify(token)

      assert_not result.valid?
      assert_equal :mismatched, result.reason
    end

    test 'a decision just inside the window still verifies' do
      assert verify(issue(issued_at: (PaperIdentityReviewReceipt::MAX_AGE - 1.minute).ago)).valid?
    end

    test 'a receipt expires at its Rails verifier deadline' do
      freeze_time do
        token = issue
        travel PaperIdentityReviewReceipt::MAX_AGE - 1.second
        assert verify(token).valid?
        travel 1.second
        assert_not verify(token).valid?
      end
    end

    test 'malformed and forged decisions are rejected rather than raising' do
      ['', 'nonsense', 'v1:abc', "v2:#{Time.current.to_i}:deadbeef",
       "v1:#{Time.current.to_i}:#{'0' * 64}"].each do |bad|
        result = verify(bad)
        assert_not result.valid?, "#{bad.inspect} must not verify"
        assert_includes %i[malformed expired mismatched], result.reason
      end
    end

    # The token carries only the fingerprint digest and verifier metadata, not applicant facts.
    test 'no identity facts travel in the token' do
      token = issue

      assert_match(/\A[a-f0-9]{64}\z/, Rails.application.message_verifier(PaperIdentityReviewReceipt::PURPOSE).verified(token, purpose: PaperIdentityReviewReceipt::PURPOSE))
      %w[John Smith 1990-04-02 john.smith@example.com 5555550100 21201 Baltimore].each do |secret|
        assert_not_includes token, secret
      end
    end

    private

    def facts(context: :self_applicant, admin: @admin, identity: @identity,
              candidates: @candidates, reasons: @reasons)
      PaperIdentityReviewReceipt::Facts.new(context, admin, identity, candidates, reasons)
    end

    def issue(issued_at: Time.current, **overrides)
      PaperIdentityReviewReceipt.issue(facts(**overrides), issued_at: issued_at)
    end

    def verify(token, **overrides)
      PaperIdentityReviewReceipt.verify(token, facts(**overrides))
    end
  end
end
