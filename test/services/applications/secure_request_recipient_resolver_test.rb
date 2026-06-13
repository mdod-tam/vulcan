# frozen_string_literal: true

require 'test_helper'

module Applications
  class SecureRequestRecipientResolverTest < ActiveSupport::TestCase
    test 'uses letter by default for a letter-preferring recipient with mailing address' do
      constituent = create(:constituent, communication_preference: 'letter')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal constituent, candidate.recipient
      assert_equal :letter, candidate.channel
    end

    test 'letter communication preference wins over text phone type' do
      constituent = create(:constituent, communication_preference: 'letter', phone_type: 'text')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal :letter, candidate.channel
    end

    test 'email communication preference routes secure requests to email' do
      constituent = create(:constituent, communication_preference: 'email', phone_type: 'text')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal :email, candidate.channel
    end

    test 'sms delivery requires explicit channel override' do
      constituent = create(:constituent, communication_preference: 'email', phone_type: 'text')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'sms' })
                  .resolve
                  .first

      assert_equal :sms, candidate.channel
    end

    test 'defaults adult application to applicant' do
      application = create(:application)

      candidates = SecureRequestRecipientResolver.new(application: application).resolve

      assert_equal [application.user], candidates.map(&:recipient)
      assert_equal [application.user_id], SecureRequestRecipientResolver.new(application: application).default_recipient_ids
    end

    test 'defaults dependent application to managing guardian when effective email uses guardian email' do
      guardian = create(:constituent, email: "guardian.default.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.default.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidates = SecureRequestRecipientResolver.new(application: application).resolve

      assert_equal [guardian], candidates.map(&:recipient)
      assert_equal :guardian, candidates.first.recipient_role
      assert_equal guardian.email, candidates.first.email
    end

    test 'defaults dependent application to dependent when effective email is separate from guardian email' do
      guardian = create(:constituent, email: "guardian.separate.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.separate.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidates = SecureRequestRecipientResolver.new(application: application).resolve

      assert_equal [dependent], candidates.map(&:recipient)
      assert_equal :constituent, candidates.first.recipient_role
      assert_equal dependent_email, candidates.first.email
    end

    test 'allows explicit email override for a letter-preferring recipient with known email' do
      constituent = create(:constituent, communication_preference: 'letter')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'email' })
                  .resolve
                  .first

      assert_equal :email, candidate.channel
      assert_equal constituent.email, candidate.email
    end

    test 'does not allow arbitrary recipient ids' do
      application = create(:application)
      stranger = create(:constituent)

      candidates = SecureRequestRecipientResolver.new(application: application, recipient_ids: [stranger.id]).resolve

      assert_empty candidates
    end

    test 'honors explicit dependent guardian and both recipient selections' do
      guardian = create(:constituent)
      dependent = create(:constituent, dependent_email: guardian.email)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      dependent_candidates = SecureRequestRecipientResolver
                             .new(application: application, recipient_ids: [dependent.id])
                             .resolve
      guardian_candidates = SecureRequestRecipientResolver
                            .new(application: application, recipient_ids: [guardian.id])
                            .resolve
      both_candidates = SecureRequestRecipientResolver
                        .new(application: application, recipient_ids: [dependent.id, guardian.id])
                        .resolve

      assert_equal [dependent], dependent_candidates.map(&:recipient)
      assert_equal [guardian], guardian_candidates.map(&:recipient)
      assert_equal [dependent, guardian], both_candidates.map(&:recipient)
    end

    test 'allows other recorded guardians only when explicitly selected' do
      managing_guardian = create(:constituent)
      other_guardian = create(:constituent)
      dependent = create(:constituent, dependent_email: managing_guardian.email)
      create(:guardian_relationship, guardian_user: managing_guardian, dependent_user: dependent, relationship_type: 'Parent')
      create(:guardian_relationship, guardian_user: other_guardian, dependent_user: dependent, relationship_type: 'Aunt')
      application = create(:application, user: dependent, managing_guardian: managing_guardian)

      default_candidates = SecureRequestRecipientResolver.new(application: application).resolve
      explicit_candidates = SecureRequestRecipientResolver
                            .new(application: application, recipient_ids: [other_guardian.id])
                            .resolve

      assert_equal [managing_guardian], default_candidates.map(&:recipient)
      assert_equal [other_guardian], explicit_candidates.map(&:recipient)
      assert_equal :guardian, explicit_candidates.first.recipient_role
      assert_equal 'Aunt', explicit_candidates.first.recipient_relationship_type
    end

    test 'does not default or route dependent candidate through non-managing guardian contact path' do
      other_guardian = create(:constituent, email: "other.guardian.#{SecureRandom.hex(3)}@example.com")
      managing_guardian = create(:constituent, email: "managing.guardian.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.real.#{SecureRandom.hex(3)}@example.com"
      dependent = create(
        :constituent,
        email: dependent_email,
        dependent_email: other_guardian.email
      )
      create(:guardian_relationship, guardian_user: other_guardian, dependent_user: dependent, relationship_type: 'Aunt')
      create(:guardian_relationship, guardian_user: managing_guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: managing_guardian)

      default_candidate = SecureRequestRecipientResolver.new(application: application).resolve.first
      dependent_candidate = SecureRequestRecipientResolver
                            .new(application: application, recipient_ids: [dependent.id])
                            .resolve
                            .first

      assert_equal dependent, default_candidate.recipient
      assert_equal dependent_email, dependent_candidate.email
      assert_not_equal other_guardian.email, dependent_candidate.email
    end

    test 'does not include alternate contact as a known or default recipient' do
      application = create(
        :application,
        alternate_contact_name: 'Helpful Person',
        alternate_contact_email: 'alternate@example.com',
        alternate_contact_phone: '410-555-0111'
      )

      resolver = SecureRequestRecipientResolver.new(application: application)

      assert_equal [application.user], resolver.known_recipients
      assert_equal [application.user_id], resolver.default_recipient_ids
    end

    test 'can resolve against a preloaded known recipient set' do
      application = create(:application)
      known_recipients = [application.user]

      candidates = SecureRequestRecipientResolver
                   .new(application: application, recipient_ids: [application.user_id],
                        known_recipients: known_recipients)
                   .resolve

      assert_equal [application.user], candidates.map(&:recipient)
    end

    test 'uses preloaded guardian relationships when resolving recipient role context' do
      dependent = create(:constituent)
      guardian = create(:constituent)
      application = create(:application, user: dependent, managing_guardian: guardian)
      relationship = create(:guardian_relationship, dependent_user: dependent, guardian_user: guardian,
                                                    relationship_type: 'parent')

      GuardianRelationship.expects(:where).never

      candidate = SecureRequestRecipientResolver
                  .new(application: application,
                       recipient_ids: [guardian.id],
                       known_recipients: [guardian],
                       guardian_relationships: [relationship])
                  .resolve
                  .first

      assert_equal guardian, candidate.recipient
      assert_equal :guardian, candidate.recipient_role
      assert_equal 'parent', candidate.recipient_relationship_type
    end
  end
end
