# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # The fingerprint decides whether a spent key replays or refuses, so its failure modes are
  # asymmetric. Collapsing two different requests into one fingerprint silently discards a change
  # the guardian was told had been applied; separating one request into two merely asks them to
  # resubmit. These tests pin the first kind.
  class DependentRequestFingerprintTest < ActiveSupport::TestCase
    test 'an identical request fingerprints identically' do
      assert_equal fingerprint, fingerprint
    end

    # Names are stored verbatim, so these are materially different persisted records. Folding case
    # or whitespace here would let a real change replay as a no-op.
    test 'a case change in a name is a different request' do
      assert_not_equal fingerprint(first_name: 'Jane'), fingerprint(first_name: 'jane')
    end

    test 'a whitespace change in a name is a different request' do
      assert_not_equal fingerprint(last_name: 'Doe'), fingerprint(last_name: ' Doe ')
    end

    test 'a case change in relationship type is a different request' do
      assert_not_equal fingerprint(relationship_type: 'Parent'),
                       fingerprint(relationship_type: 'parent')
    end

    # A hand-rolled "key=value" join has no field boundaries: a value containing the separator can
    # reproduce a different field set's payload. JSON serialization escapes them.
    test 'a value containing the field separator cannot collide with another field set' do
      collider = fingerprint(first_name: "Jane\nlast_name=Doe")
      plain = fingerprint(first_name: 'Jane', last_name: 'Doe')

      assert_not_equal plain, collider
    end

    test 'a quote or brace in a value does not collide' do
      assert_not_equal fingerprint(first_name: 'Jane"'), fingerprint(first_name: 'Jane')
      assert_not_equal fingerprint(first_name: '{"last_name":"Doe"}'), fingerprint(first_name: 'Jane')
    end

    # Canonicalized by the writer, so two spellings of one stored value are the same request.
    test 'equivalent date formats are the same request' do
      assert_equal fingerprint(date_of_birth: '05/15/2010'), fingerprint(date_of_birth: '2010-05-15')
    end

    test 'equivalent phone formatting is the same request' do
      assert_equal fingerprint(phone: '555-555-0011'), fingerprint(phone: '(555) 555-0011')
    end

    test 'equivalent email casing is the same request' do
      assert_equal fingerprint(email: 'Jane@Example.com'), fingerprint(email: 'jane@example.com')
    end

    test 'a changed date of birth is a different request' do
      assert_not_equal fingerprint(date_of_birth: '2010-05-15'), fingerprint(date_of_birth: '2011-05-15')
    end

    # Contact the guardian owns is never persisted from the submitted field, so a stale value left
    # in a hidden input must not make an otherwise identical request look different.
    test 'guardian-owned contact is excluded from the fingerprint' do
      assert_equal fingerprint(use_guardian_email: '1', email: 'ignored@example.com'),
                   fingerprint(use_guardian_email: '1', email: 'also-ignored@example.com')
      assert_equal fingerprint(use_guardian_phone: '1', phone: '555-555-1111'),
                   fingerprint(use_guardian_phone: '1', phone: '555-555-2222')
    end

    test 'dependent-owned contact is included in the fingerprint' do
      assert_not_equal fingerprint(email: 'one@example.com'), fingerprint(email: 'two@example.com')
      assert_not_equal fingerprint(phone: '555-555-0011'), fingerprint(phone: '555-555-9999')
    end

    test 'changing the contact choice is a different request' do
      assert_not_equal fingerprint(use_guardian_email: '0'), fingerprint(use_guardian_email: '1')
    end

    test 'every disability selection is covered' do
      DependentRequestFingerprint::DISABILITY_FIELDS.each do |field|
        assert_not_equal fingerprint(field => false), fingerprint(field => true),
                         "#{field} must be part of the request fingerprint"
      end
    end

    test 'newsletter consent and phone type are covered' do
      assert_not_equal fingerprint(newsletter_signup: false), fingerprint(newsletter_signup: true)
      assert_not_equal fingerprint(phone_type: 'voice'), fingerprint(phone_type: 'videophone')
    end

    test 'the fingerprint carries its canonical-form version' do
      assert_match(/\Av1:[a-f0-9]{64}\z/, fingerprint)
    end

    # The point of keying is that the digest is not recomputable from the payload alone -- otherwise
    # the stored column is a searchable index into a date of birth and phone number. Proving that
    # needs the *key* varied while the input is held identical: any formatted digest, keyed or not,
    # would survive a weaker check like comparing the value to a hash of itself.
    test 'identical input under a different server key produces a different fingerprint' do
      first = with_generated_key('key-material-one') { fingerprint }
      second = with_generated_key('key-material-two') { fingerprint }

      assert_not_equal first, second,
                       'the fingerprint must depend on the server key, not only on the payload'
      assert_equal first, with_generated_key('key-material-one') { fingerprint },
                   'and must stay stable for one key'
    end



    private

    def with_generated_key(material)
      Rails.application.key_generator.stub(:generate_key, material) { yield }
    end

    DEFAULTS = {
      first_name: 'Jane',
      last_name: 'Doe',
      date_of_birth: '2010-05-15',
      email: 'jane.doe@example.com',
      phone: '555-555-0011',
      phone_type: 'voice',
      newsletter_signup: false,
      hearing_disability: true
    }.freeze

    def fingerprint(**overrides)
      relationship_type = overrides.delete(:relationship_type) || 'Parent'
      use_guardian_email = overrides.delete(:use_guardian_email) || '0'
      use_guardian_phone = overrides.delete(:use_guardian_phone) || '0'

      DependentRequestFingerprint.new(
        dependent_params: DEFAULTS.merge(overrides),
        relationship_type: relationship_type,
        use_guardian_email: use_guardian_email,
        use_guardian_phone: use_guardian_phone
      ).to_s
    end
  end
end
