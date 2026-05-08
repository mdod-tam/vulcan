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
