# frozen_string_literal: true

require 'test_helper'

module Applications
  # A decision that survives a change to the identity it was made about is worse than no decision at
  # all: it launders "I checked" from one applicant onto another. These pin what invalidates it.
  class PaperIdentityDecisionTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @other_admin = create(:admin)
      # The full fact set duplicate detection receives, already canonicalized by the caller's
      # duplicate_detection_attrs -- this object fingerprints what it is given rather than
      # re-deriving normalization, so there is one definition of "the same facts".
      @identity = { first_name: 'John', last_name: 'Smith', date_of_birth: Date.new(1990, 4, 2),
                    email: 'john.smith@example.com', phone: '5555550100',
                    physical_address_1: '1 Main St', physical_address_2: nil,
                    city: 'Baltimore', state: 'MD', zip_code: '21201' }
      # The presented snapshot -- the exact rows the browser rendered -- not a list of ids.
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

    # The whole point: the decision was about this applicant, so changing who is being created must
    # invalidate it. This is the "searched for John, submitted Jane" case.
    # Materially different values per field, not a suffix: appending to a date still casts to the
    # same day and appending to a phone still normalizes to the same digits, and canonicalization is
    # meant to absorb exactly that.
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

    # Address is part of what detection scores, so it is part of what a decision is about. Binding
    # only name/DOB/contact left a gap: swapping one non-matching address for another preserves the
    # candidate ids and reasons, so the old decision would have stayed valid.
    # An absent second address line and a cleared one are different submissions. Stringifying every
    # value would collapse them and let one be substituted under a decision issued for the other.
    test 'a blank value is not the same fact as a missing one' do
      # Issued at one fixed instant, because the token embeds its timestamp: two calls straddling a
      # second boundary would differ even if the fingerprints underneath were identical, and the
      # assertion would pass without proving anything.
      at = Time.current
      assert_not_equal issue(identity: @identity.merge(physical_address_2: nil), issued_at: at),
                       issue(identity: @identity.merge(physical_address_2: ''), issued_at: at)
    end

    # The same guarantee from the verification side, which is where it actually matters: a decision
    # issued for a missing value must not verify once that value is present but blank.
    test 'a decision issued for a missing value does not verify against a blank one' do
      token = issue(identity: @identity.merge(physical_address_2: nil))

      assert_not verify(token, identity: @identity.merge(physical_address_2: '')).valid?
    end

    test 'key order does not change the identity' do
      shuffled = @identity.to_a.reverse.to_h
      assert verify(issue(identity: shuffled)).valid?
    end

    # A different candidate set means staff reviewed a different set of possibilities, whether
    # because someone created a record in between or because the request supplied its own list.
    test 'a changed candidate set invalidates the decision' do
      token = issue
      newcomer = { id: 99, name: 'Jane Smith', date_of_birth: 'April 2, 1990',
                   city: 'Baltimore', state: 'MD', zip_code: '21201', selectable: true }
      result = verify(token, candidates: @candidates + [newcomer])

      assert_not result.valid?
      assert_equal :mismatched, result.reason
    end

    # The reason ids alone were not enough: staff decide on what the row *says*. Each of these
    # changes a fact that was on screen while leaving the candidate ids and the reason codes
    # untouched, which is exactly the case an id-only binding accepted.
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

    # Whether a row could be picked at all is part of what staff were looking at: "these are
    # different people" means something different when the alternative was not offered.
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

    # A decision is one admin's attestation, so it cannot be carried across accounts.
    test 'another admin cannot use this decision' do
      assert_not verify(issue, admin: @other_admin).valid?
    end

    test 'the decision context is bound' do
      assert_not verify(issue(context: :self_applicant), context: :dependent).valid?
    end

    # An old form left open overnight must not authorize a creation the next day even when nothing
    # about the identity changed.
    test 'a decision expires' do
      token = issue(issued_at: 2.hours.ago)
      result = verify(token)

      assert_not result.valid?
      assert_equal :expired, result.reason
    end

    test 'a decision just inside the window still verifies' do
      assert verify(issue(issued_at: (PaperIdentityDecision::MAX_AGE - 1.minute).ago)).valid?
    end

    # The expiry reported to the browser and the expiry the server enforces must be the same instant,
    # or a countdown shows time remaining on a token that has already stopped working.
    test 'the reported expiry is the first instant verification rejects' do
      issued_at = Time.current
      token = issue(issued_at: issued_at)
      expires_at = PaperIdentityDecision.expires_at(token)

      assert verify(token, now: expires_at - 1.second).valid?, 'still valid one second before'
      assert_not verify(token, now: expires_at).valid?, 'rejected at the reported instant'
    end

    test 'malformed and forged decisions are rejected rather than raising' do
      ['', 'nonsense', 'v1:abc', "v2:#{Time.current.to_i}:deadbeef",
       "v1:#{Time.current.to_i}:#{'0' * 64}"].each do |bad|
        result = verify(bad)
        assert_not result.valid?, "#{bad.inspect} must not verify"
        assert_includes %i[malformed expired mismatched], result.reason
      end
    end

    # The token carries only a version, a timestamp, and a digest -- never the applicant's facts.
    test 'no identity facts travel in the token' do
      token = issue

      assert_match(/\Av1:\d+:[a-f0-9]{64}\z/, token)
      %w[John Smith 1990-04-02 john.smith@example.com 5555550100 21201 Baltimore].each do |secret|
        assert_not_includes token, secret
      end
    end

    private

    def facts(context: :self_applicant, admin: @admin, identity: @identity,
              candidates: @candidates, reasons: @reasons)
      PaperIdentityDecision::Facts.new(context, admin, identity, candidates, reasons)
    end

    def issue(issued_at: Time.current, **overrides)
      PaperIdentityDecision.issue(facts(**overrides), issued_at: issued_at)
    end

    def verify(token, now: Time.current, **overrides)
      PaperIdentityDecision.verify(token, facts(**overrides), now: now)
    end
  end
end
