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

    test 'explicit sms override fails strictly when the selected phone is synthetic' do
      guardian = create(:constituent, phone: '410-555-0100')
      dependent_email = "dependent.sms.#{SecureRandom.hex(3)}@example.com"
      dependent = create(
        :constituent,
        email: dependent_email,
        phone: '000-123-4567',
        dependent_email: dependent_email,
        dependent_phone: guardian.phone
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application,
                       recipient_ids: [dependent.id],
                       channel_overrides: { dependent.id => 'sms' })
                  .resolve
                  .first

      assert_equal dependent, candidate.recipient
      assert_nil candidate.phone
      assert_nil candidate.channel
      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_not candidate.success?
      assert_includes candidate.available_channels, :email
      assert_not_includes candidate.available_channels, :sms
    end

    test 'guardian phone stored in +1 format is still recognized as guardian-owned' do
      # Validation accepts the raw dependent_phone with a leading 1. The guardian phone is canonical.
      # User.normalize_phone must match their owners before the resolver applies phone_type.
      guardian = create(:constituent, phone: '410-555-0170', phone_type: 'voice')
      dependent_email = "dependent.plusone.#{SecureRandom.hex(3)}@example.com"
      dependent = create(
        :constituent,
        email: dependent_email,
        phone: '000-123-4567',
        phone_type: 'text',
        dependent_email: dependent_email,
        dependent_phone: '+1 410-555-0170'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application,
                       recipient_ids: [dependent.id],
                       channel_overrides: { dependent.id => 'sms' })
                  .resolve
                  .first

      assert_nil candidate.phone
      assert_nil candidate.channel
      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_includes candidate.available_channels, :email
      assert_not_includes candidate.available_channels, :sms
    end

    test 'guardian email matching uses canonical normalization for ownership' do
      hex = SecureRandom.hex(3)
      guardian = create(:constituent, email: "guardian.case.#{hex}@example.com")
      dependent_email = "dependent.case.#{SecureRandom.hex(3)}@example.com"
      dependent = create(
        :constituent,
        email: dependent_email,
        # Raw dependent_email retains case and whitespace.
        dependent_email: "  Guardian.Case.#{hex}@EXAMPLE.com "
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_equal guardian, candidate.contact_owner
      assert_equal :managing_guardian, candidate.contact_source
      assert_equal guardian.email, candidate.email
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

    test 'records contact owner and source for a guardian-routed dependent' do
      guardian = create(:constituent, email: "guardian.owner.#{SecureRandom.hex(3)}@example.com",
                                      phone: '410-555-0160', phone_type: 'text')
      dependent = create(
        :constituent,
        email: "dependent.owner.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      default_candidate = SecureRequestRecipientResolver.new(application: application).resolve.first
      dependent_candidate = SecureRequestRecipientResolver
                            .new(application: application, recipient_ids: [dependent.id])
                            .resolve
                            .first

      assert_equal guardian, default_candidate.contact_owner
      assert_equal :guardian_relationship, default_candidate.contact_source
      assert_equal guardian.email, default_candidate.email
      assert_equal guardian.phone, default_candidate.phone
      assert_equal 'text', default_candidate.phone_type
      assert_equal guardian, default_candidate.address_owner
      assert_includes default_candidate.available_channels, :sms

      assert_equal dependent, dependent_candidate.recipient
      assert_equal guardian, dependent_candidate.contact_owner
      assert_equal :managing_guardian, dependent_candidate.contact_source
      assert_equal guardian.email, dependent_candidate.email
    end

    test 'records dependent-owned contact field provenance' do
      guardian = create(:constituent, email: "guardian.depfield.#{SecureRandom.hex(3)}@example.com")
      dependent_email = "dependent.field.#{SecureRandom.hex(3)}@example.com"
      dependent = create(
        :constituent,
        email: "dependent.field.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: dependent_email,
        dependent_phone: '410-555-0161',
        phone_type: 'text'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_equal dependent, candidate.contact_owner
      assert_equal :dependent_contact, candidate.contact_source
      assert_equal dependent_email, candidate.email
      assert_equal '410-555-0161', candidate.phone
      assert_equal 'text', candidate.phone_type
      assert_includes candidate.available_channels, :sms
    end

    test 'records guardian relationship provenance for an explicitly selected guardian' do
      managing_guardian = create(:constituent)
      other_guardian = create(:constituent)
      dependent = create(:constituent, dependent_email: managing_guardian.email)
      create(:guardian_relationship, guardian_user: managing_guardian, dependent_user: dependent,
                                     relationship_type: 'Parent')
      create(:guardian_relationship, guardian_user: other_guardian, dependent_user: dependent,
                                     relationship_type: 'Aunt')
      application = create(:application, user: dependent, managing_guardian: managing_guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [other_guardian.id])
                  .resolve
                  .first

      assert_equal other_guardian, candidate.contact_owner
      assert_equal :guardian_relationship, candidate.contact_source
      assert_equal other_guardian, candidate.address_owner
    end

    test 'rejects synthetic email as a contact path' do
      constituent = nil
      Current.paper_context = true
      begin
        constituent = create(:constituent,
                             email: "adult.synthetic.#{SecureRandom.hex(3)}@system.matvulcan.local",
                             phone: nil,
                             communication_preference: 'letter')
      ensure
        Current.reset
      end
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_nil candidate.email
      assert_equal :letter, candidate.channel
      assert_not_includes candidate.available_channels, :email
    end

    test 'routes address-only constituent to letter' do
      constituent = nil
      Current.paper_context = true
      begin
        constituent = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      ensure
        Current.reset
      end
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert candidate.success?
      assert_equal :letter, candidate.channel
      assert_equal %i[letter], candidate.available_channels
      assert_equal constituent, candidate.address_owner
      assert_nil candidate.email
      assert_nil candidate.phone
    end

    test 'address-only resolution creates no email phone or sms route' do
      constituent = nil
      Current.paper_context = true
      begin
        constituent = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      ensure
        Current.reset
      end
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'email' })
                  .resolve
                  .first

      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_nil candidate.channel
    end

    test 'fails with no_contact_path when no digital contact and incomplete address' do
      constituent = nil
      Current.paper_context = true
      begin
        constituent = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      ensure
        Current.reset
      end
      # Direct updates model an incomplete legacy address.
      constituent.update_columns(physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_not candidate.success?
      assert_equal :no_contact_path, candidate.failure_reason
      assert_empty candidate.available_channels
    end

    test 'explicit letter override fails without fallback when the address is incomplete' do
      constituent = create(:constituent, communication_preference: 'email', physical_address_1: nil)
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'letter' })
                  .resolve
                  .first

      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_nil candidate.channel
      assert_includes candidate.available_channels, :email
    end

    test 'explicit email override fails strictly without a real email' do
      constituent = nil
      Current.paper_context = true
      begin
        constituent = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      ensure
        Current.reset
      end
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'email' })
                  .resolve
                  .first

      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_nil candidate.channel
    end

    test 'forged unknown channel value fails without fallback' do
      application = create(:application)

      candidate = SecureRequestRecipientResolver
                  .new(application: application,
                       channel_overrides: { application.user_id => 'carrier_pigeon' })
                  .resolve
                  .first

      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_nil candidate.channel
    end

    test 'voice phone does not offer sms' do
      constituent = create(:constituent, phone: '410-555-0162', phone_type: 'voice')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'sms' })
                  .resolve
                  .first

      assert_equal :invalid_channel_override, candidate.failure_reason
      assert_not_includes candidate.available_channels, :sms
    end

    test 'videophone does not offer sms' do
      constituent = create(:constituent, phone: '410-555-0163', phone_type: 'videophone')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_not_includes candidate.available_channels, :sms
    end

    test 'malformed stored phone does not offer sms and is not snapshotted' do
      constituent = create(:constituent, phone: '410-555-0165', phone_type: 'text')
      # Direct updates model malformed legacy data.
      constituent.update_column(:phone, '123')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { constituent.id => 'sms' })
                  .resolve
                  .first

      assert_nil candidate.phone
      assert_equal :invalid_channel_override, candidate.failure_reason
    end

    test 'sms validates the phone type of the owning source rather than the logical recipient' do
      guardian = create(:constituent, email: "guardian.voice.#{SecureRandom.hex(3)}@example.com",
                                      phone: '410-555-0164', phone_type: 'voice')
      dependent = create(
        :constituent,
        email: "dependent.voice.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email,
        phone_type: 'text'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, channel_overrides: { guardian.id => 'sms' })
                  .resolve
                  .first

      assert_equal guardian, candidate.recipient
      assert_equal 'voice', candidate.phone_type
      assert_equal :invalid_channel_override, candidate.failure_reason
    end

    test 'dependent letter delivery addresses the managing guardian household' do
      guardian = create(:constituent, email: "guardian.letter.#{SecureRandom.hex(3)}@example.com",
                                      physical_address_1: '9 Guardian Way',
                                      communication_preference: 'letter')
      dependent = create(
        :constituent,
        email: "dependent.letter.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email,
        communication_preference: 'letter'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal guardian, candidate.recipient
      assert_equal :letter, candidate.channel
      assert_equal guardian, candidate.address_owner
    end

    test 'letter route requires the address owner to have a complete address' do
      guardian = create(:constituent, email: "guardian.noaddr.#{SecureRandom.hex(3)}@example.com",
                                      physical_address_1: nil, city: nil, state: nil, zip_code: nil)
      dependent = create(
        :constituent,
        email: "dependent.noaddr.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal guardian, candidate.address_owner
      assert_not_includes candidate.available_channels, :letter
      assert_equal :email, candidate.channel
    end

    test 'respects action-permitted channels' do
      constituent = create(:constituent, communication_preference: 'letter')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, permitted_channels: %i[email])
                  .resolve
                  .first

      assert_equal %i[email], candidate.available_channels
      assert_equal :email, candidate.channel
    end

    test 'digital-only action reports no route for an address-only constituent' do
      constituent = nil
      Current.paper_context = true
      begin
        constituent = create(:constituent, email: nil, phone: nil, communication_preference: 'letter')
      ensure
        Current.reset
      end
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, permitted_channels: %i[email sms])
                  .resolve
                  .first

      assert_equal :no_contact_path, candidate.failure_reason
      assert_empty candidate.available_channels
    end

    test 'email preference keeps email even when a letter route is also available' do
      constituent = create(:constituent, communication_preference: 'email')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal :email, candidate.channel
      assert_includes candidate.available_channels, :letter
    end

    test 'exposes per-channel owner eligibility without hiding contact reality' do
      guardian = create(:constituent, email: "guardian.owner.#{SecureRandom.hex(3)}@example.com",
                                      physical_address_1: '9 Guardian Way')
      dependent = create(
        :constituent,
        email: "dependent.owner.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)
      guardian.update!(status: :suspended)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_includes candidate.available_channels, :email
      assert_includes candidate.available_channels, :letter
      assert_empty candidate.deliverable_channels
      assert_equal %i[email letter], candidate.owner_ineligible_channels.sort
      assert_equal :owner_ineligible, candidate.channel_eligibility[:email]
      assert_equal :owner_ineligible, candidate.channel_eligibility[:letter]
      assert_equal :no_contact_path, candidate.failure_reason
    end

    test 'falls back to an eligible digital route when only the letter owner is ineligible' do
      # Only the letter route belongs to the suspended guardian.
      guardian = create(:constituent, physical_address_1: '9 Guardian Way')
      dependent_email = "dependent.mixed.#{SecureRandom.hex(3)}@example.com"
      dependent = create(:constituent, email: dependent_email, dependent_email: dependent_email,
                                       communication_preference: 'letter')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)
      guardian.update!(status: :suspended)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_equal :ok, candidate.channel_eligibility[:email]
      assert_equal :owner_ineligible, candidate.channel_eligibility[:letter]
      assert_equal %i[email], candidate.deliverable_channels
      assert_equal %i[letter], candidate.owner_ineligible_channels
      assert_equal :email, candidate.channel
      assert candidate.success?
    end

    test 'records the letter address-owner delivery source for guardian-household letters' do
      guardian = create(:constituent, email: "guardian.dsrc.#{SecureRandom.hex(3)}@example.com",
                                      physical_address_1: '9 Guardian Way',
                                      communication_preference: 'letter')
      dependent = create(
        :constituent,
        email: "dependent.dsrc.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email,
        communication_preference: 'letter'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_equal dependent, candidate.recipient
      assert_equal :letter, candidate.channel
      assert_equal :managing_guardian, candidate.delivery_source
      assert_equal guardian, candidate.delivery_owner
    end

    test 'records constituent delivery source for a self-addressed letter' do
      constituent = create(:constituent, physical_address_1: '1 Home St',
                                         communication_preference: 'letter')
      application = create(:application, user: constituent)

      candidate = SecureRequestRecipientResolver.new(application: application).resolve.first

      assert_equal :letter, candidate.channel
      assert_equal :constituent, candidate.delivery_source
      assert_equal constituent, candidate.delivery_owner
    end

    test 'records guardian relationship delivery source for a guardian recipient letter' do
      guardian = create(:constituent, physical_address_1: '9 Guardian Way',
                                      communication_preference: 'letter')
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [guardian.id])
                  .resolve
                  .first

      assert_equal :guardian, candidate.recipient_role
      assert_equal :letter, candidate.channel
      assert_equal :guardian_relationship, candidate.delivery_source
      assert_equal guardian, candidate.delivery_owner
    end

    test 'digital delivery source matches the contact source' do
      guardian = create(:constituent, email: "guardian.ddig.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.ddig.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_equal :email, candidate.channel
      assert_equal :managing_guardian, candidate.delivery_source
      assert_equal guardian, candidate.delivery_owner
    end

    # The selected channel owns delivery_source. An email-first source would mislabel this SMS as dependent_contact.
    test 'delivery source follows the selected channel when email and phone provenance differ' do
      guardian = create(:constituent, email: "guardian.mixed.#{SecureRandom.hex(3)}@example.com")
      dependent = create(
        :constituent,
        email: "dependent.mixed.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: "dependent-owned.#{SecureRandom.hex(3)}@example.com",
        phone: "555-#{rand(200..899)}-#{rand(1000..9999)}",
        phone_type: 'text'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      email_candidate = SecureRequestRecipientResolver
                        .new(application: application, recipient_ids: [dependent.id])
                        .resolve
                        .first

      assert_equal :email, email_candidate.channel
      assert_equal :dependent_contact, email_candidate.delivery_source
      assert_equal dependent, email_candidate.delivery_owner

      sms_candidate = SecureRequestRecipientResolver
                      .new(application: application, recipient_ids: [dependent.id],
                           channel_overrides: { dependent.id => 'sms' })
                      .resolve
                      .first

      assert_equal :sms, sms_candidate.channel
      assert_equal :constituent, sms_candidate.delivery_source
      assert_equal dependent, sms_candidate.delivery_owner
      assert_equal dependent, sms_candidate.delivery_owner_for(:email)
      assert_equal dependent, sms_candidate.delivery_owner_for(:sms)
    end

    test 'delivery owner is per channel: letters follow the address owner, digital the contact owner' do
      guardian = create(:constituent, email: "guardian.perch.#{SecureRandom.hex(3)}@example.com",
                                      physical_address_1: '9 Guardian Way')
      dependent = create(
        :constituent,
        email: "dependent.perch.#{SecureRandom.hex(3)}@system.matvulcan.local",
        dependent_email: guardian.email,
        phone: "555-#{rand(200..899)}-#{rand(1000..9999)}",
        phone_type: 'text'
      )
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      application = create(:application, user: dependent, managing_guardian: guardian)

      candidate = SecureRequestRecipientResolver
                  .new(application: application, recipient_ids: [dependent.id])
                  .resolve
                  .first

      assert_equal guardian, candidate.delivery_owner_for(:email)
      assert_equal guardian, candidate.delivery_owner_for(:sms)
      assert_equal guardian, candidate.delivery_owner_for(:letter)
      assert_equal guardian, candidate.email_owner
      assert_equal guardian, candidate.phone_owner
      assert_equal guardian, candidate.address_owner
    end
  end
end
