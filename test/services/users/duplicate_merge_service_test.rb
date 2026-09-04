# frozen_string_literal: true

require 'test_helper'

module Users
  class DuplicateMergeServiceTest < ActiveSupport::TestCase
    setup do
      @admin = create(:admin)
      @canonical = create(:constituent, email: "portal-#{SecureRandom.hex(3)}@example.com", phone: nil)
      @duplicate = phone_only_constituent(phone: '555-777-8888')
      @review_case = open_case(subject: @duplicate, candidate: @canonical, reason: 'exact_phone')
    end

    test 'merges a phone-only paper record into an email-backed portal account' do
      duplicate_app = create(:application, user: @duplicate)
      session = @duplicate.sessions.create!(session_token: SecureRandom.hex(16), user_agent: 'test', ip_address: '127.0.0.1')

      result = nil
      assert_difference 'Event.where(action: \'duplicate_user_merged\').count', 1 do
        result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      end

      assert result.success?, result.message

      @canonical.reload
      @duplicate.reload
      assert_equal '555-777-8888', @canonical.phone
      assert @canonical.real_phone?
      assert @canonical.real_email?, 'canonical keeps its portal email'
      assert_equal 'voice', @canonical.phone_type

      assert @duplicate.merged?
      assert_equal @canonical.id, @duplicate.merged_into_user_id
      assert_equal @admin.id, @duplicate.merged_by_id
      assert @duplicate.inactive?
      assert_not @duplicate.needs_duplicate_review
      assert_nil @duplicate.phone, 'duplicate releases the moved phone'

      assert_equal @canonical.id, duplicate_app.reload.user_id
      assert_not Session.exists?(session.id), 'duplicate session expired'

      @review_case.reload
      assert_equal 'resolved_merged', @review_case.status
      assert_equal 'same_person_confirmed', @review_case.resolution_determination
    end

    test 'accepts shared contact and delivery facts only while both locked records agree' do
      shared_address = {
        physical_address_1: '100 Shared Street',
        physical_address_2: nil,
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201'
      }
      @canonical.update!(phone: nil, phone_type: nil, communication_preference: :letter, **shared_address)
      @duplicate.update!(
        email: "shared-duplicate-#{SecureRandom.hex(4)}@example.com",
        phone: nil,
        phone_type: nil,
        communication_preference: :letter,
        **shared_address
      )

      result = merge(
        contact_choices: { phone: 'agreed', phone_type: nil, email: 'canonical', address: 'agreed' },
        delivery_choice: 'agreed'
      )

      assert result.success?, result.message
      metadata = @review_case.reload.resolution_metadata
      assert_equal 'agreed', metadata.dig('contact_choices', 'phone')
      assert_equal 'agreed', metadata.dig('contact_choices', 'address')
      assert_equal 'agreed', metadata['delivery_choice']
    end

    test 'refuses a forged shared-phone claim before merge or audit' do
      assert_no_difference 'Event.where(action: \'duplicate_user_merged\').count' do
        result = merge(
          contact_choices: { phone: 'agreed', phone_type: 'voice', email: 'canonical', address: 'canonical' }
        )

        assert result.failure?
        assert_match(/phone values no longer agree/i, result.message)
      end
      assert_not @duplicate.reload.merged?
    end

    test 'refuses a forged shared-address claim before merge or audit' do
      @duplicate.update!(physical_address_1: 'Different address')

      assert_no_difference 'Event.where(action: \'duplicate_user_merged\').count' do
        result = merge(
          contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'agreed' }
        )

        assert result.failure?
        assert_match(/addresses no longer agree/i, result.message)
      end
      assert_not @duplicate.reload.merged?
    end

    test 'refuses a forged shared-delivery claim before merge or audit' do
      assert_no_difference 'Event.where(action: \'duplicate_user_merged\').count' do
        result = merge(delivery_choice: 'agreed')

        assert result.failure?
        assert_match(/delivery routes no longer agree/i, result.message)
      end
      assert_not @duplicate.reload.merged?
    end

    test 'refuses a forged shared-phone-type claim before merge or audit' do
      @canonical.update!(phone: '410-555-0191', phone_type: 'text')

      assert_no_difference 'Event.where(action: \'duplicate_user_merged\').count' do
        result = merge(
          contact_choices: { phone: 'duplicate', phone_type: 'agreed', email: 'canonical', address: 'canonical' }
        )

        assert result.failure?
        assert_match(/phone types no longer agree/i, result.message)
      end
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge without same-person confirmation' do
      result = merge(same_person_confirmed: false)
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge for a non-admin actor' do
      result = merge(actor: create(:constituent))
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    %i[inactive suspended].each do |status|
      test "blocks merge for a #{status} admin actor" do
        @admin.update!(status: status)

        result = merge

        assert result.failure?
        assert_match(/admin actor is required/i, result.message)
        assert_not @duplicate.reload.merged?
      end
    end

    test 'blocks merge when the duplicate has a pending recovery request' do
      @duplicate.recovery_requests.create!(status: 'pending', ip_address: '127.0.0.1', user_agent: 'test')
      result = merge
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the duplicate is recipient of an active secure request form' do
      application = create(:application, user: @duplicate)
      create(:secure_request_form, application: application, recipient: @duplicate)
      result = merge
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge that would create conflicting active applications' do
      create(:application, user: @canonical, status: :in_progress)
      create(:application, user: @duplicate, status: :in_progress)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'coalesces the same dependent relationship and keeps the dependent application on the dependent' do
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: dependent)
      create(:guardian_relationship, guardian_user: @duplicate, dependent_user: dependent)
      application = create(:application, user: dependent, managing_guardian: @duplicate)

      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })

      assert result.success?, result.message
      assert_equal 1, GuardianRelationship.where(guardian_id: @canonical.id, dependent_id: dependent.id).count
      assert_not GuardianRelationship.exists?(guardian_id: @duplicate.id)
      assert_equal dependent.id, application.reload.user_id, 'a guardian merge never moves the dependent-owned application'
      assert_equal @canonical.id, application.managing_guardian_id
      assert_equal 1, result.data[:summary][:guardian_relationships_coalesced]
    end

    test 'blocks choosing a phone-only record as canonical when the other record is email-backed' do
      phone_only_subject = phone_only_constituent(phone: '555-222-3333')
      email_backed = create(:constituent, email: "portal2-#{SecureRandom.hex(3)}@example.com")
      review_case = open_case(subject: phone_only_subject, candidate: email_backed, reason: 'exact_phone')

      result = DuplicateMergeService.new(
        actor: @admin,
        duplicate_review_case: review_case,
        canonical_user: phone_only_subject,
        duplicate_user: email_backed,
        same_person_confirmed: true,
        rationale: 'same person confirmed via support call',
        reason_codes: %w[exact_phone],
        contact_choices: { email: 'duplicate', phone: 'canonical', phone_type: 'voice', address: 'canonical' },
        delivery_choice: 'canonical'
      ).call

      assert result.failure?
      assert_match(/email-backed record must be chosen as canonical/i, result.message)
      assert_not phone_only_subject.reload.merged?
      assert_not email_backed.reload.merged?
    end

    test 'blocks merge when both records are email-backed and the duplicate email is chosen' do
      other_canonical = create(:constituent, email: "portal4-#{SecureRandom.hex(3)}@example.com")
      other_duplicate = create(:constituent, email: "portal5-#{SecureRandom.hex(3)}@example.com")
      review_case = open_case(subject: other_duplicate, candidate: other_canonical, reason: 'name_dob')

      result = DuplicateMergeService.new(
        actor: @admin,
        duplicate_review_case: review_case,
        canonical_user: other_canonical,
        duplicate_user: other_duplicate,
        same_person_confirmed: true,
        rationale: 'same person confirmed via support call',
        reason_codes: %w[name_dob],
        contact_choices: { email: 'duplicate', phone: 'canonical', phone_type: 'voice', address: 'canonical' },
        delivery_choice: 'canonical'
      ).call

      assert result.failure?
      assert_match(/canonical record's own login email must survive/i, result.message)
      assert_not other_canonical.reload.merged?
      assert_not other_duplicate.reload.merged?
    end

    test 'blocks merge when the canonical survivor is already merged' do
      other = create(:constituent)
      @canonical.update!(merged_into_user: other, merged_at: Time.current)
      result = merge
      assert result.failure?
      assert_match(/already been merged/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the canonical survivor is inactive' do
      @canonical.update!(status: :inactive)
      result = merge
      assert result.failure?
      assert_match(/active record/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the duplicate is inactive' do
      @duplicate.update!(status: :inactive)
      result = merge
      assert result.failure?
      assert_match(/duplicate record must be an active record/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the duplicate is suspended' do
      @duplicate.update!(status: :suspended)
      result = merge
      assert result.failure?
      assert_match(/duplicate record must be an active record/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the pair does not include the case subject' do
      other_candidate = create(:constituent, email: "other-#{SecureRandom.hex(3)}@example.com")
      @review_case.duplicate_review_case_candidates.create!(candidate_user: other_candidate, match_reason: 'name_dob', snapshot: {})
      # @canonical and other_candidate are both candidates, but the subject (@duplicate) is absent.
      result = merge(canonical_user: @canonical, duplicate_user: other_candidate)
      assert result.failure?
      assert_match(/subject must be one of the two records/i, result.message)
      assert_not other_candidate.reload.merged?
    end

    test 'blocks stranding an email-backed portal account without a real email' do
      duplicate_without_email = @duplicate # phone-only, no real email
      result = merge(
        duplicate_user: duplicate_without_email,
        contact_choices: { email: 'duplicate', phone: 'duplicate', phone_type: 'voice', address: 'canonical' }
      )
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    test 'requires an explicit phone type when a real phone survives' do
      result = merge(contact_choices: { phone: 'duplicate', email: 'canonical', address: 'canonical' })
      assert result.failure?
      assert_not @duplicate.reload.merged?
    end

    # phone_type doubles as "preferred contact method", so its enum also carries the legacy
    # non-phone modes contact_email => 'email' and contact_letter => 'letter'. The merge form
    # offers only real telephone routes; a forged request must not be able to store "reach this
    # person by email" as the canonical's phone preference, which then renders as their contact
    # method in evaluator and trainer notifications.
    %w[contact_email contact_letter email letter].each do |forged_phone_type|
      test "blocks merge when phone type #{forged_phone_type} is not a real telephone route" do
        result = merge(contact_choices: { phone: 'duplicate', phone_type: forged_phone_type,
                                          email: 'canonical', address: 'canonical' })
        assert result.failure?
        assert_match(/phone type/i, result.message)
        assert_not @duplicate.reload.merged?
      end
    end

    # Reason codes become immutable resolution metadata and audit evidence, so they are validated
    # against a server-owned vocabulary rather than accepted from the request.
    test 'blocks merge when a reason code is outside the server-owned vocabulary' do
      result = merge(reason_codes: ['exact_phone', 'attacker supplied note'])
      assert result.failure?
      assert_match(/unsupported reason/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when too many reason codes are submitted' do
      result = merge(reason_codes: Array.new(DuplicateReviewCase::MAX_REASON_CODES + 1) { |i| "code-#{i}" })
      assert result.failure?
      assert_match(/too many reason/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    # The merge form falls back to 'admin_reviewed' for a case opened without detection reasons,
    # so that operator code must stay in the vocabulary or every such merge would be rejected.
    test 'accepts the admin_reviewed operator reason code the merge form falls back to' do
      result = merge(reason_codes: %w[admin_reviewed])
      assert result.success?, result.message
      assert @duplicate.reload.merged?
    end

    test 'blocks merge when a contact choice is missing' do
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', address: 'canonical' })
      assert result.failure?
      assert_match(/explicit email choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when a contact choice is invalid' do
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'nonsense', address: 'canonical' })
      assert result.failure?
      assert_match(/invalid email choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the delivery choice is missing' do
      result = merge(delivery_choice: nil)
      assert result.failure?
      assert_match(/explicit delivery route choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when the delivery choice is invalid' do
      result = merge(delivery_choice: 'nonsense')
      assert result.failure?
      assert_match(/invalid delivery route choice/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'blocks merge when another open case has the duplicate as its subject' do
      third_party = create(:constituent, email: "third-#{SecureRandom.hex(3)}@example.com")
      open_case(subject: @duplicate, candidate: third_party, reason: 'name_dob')

      result = merge
      assert result.failure?
      assert_match(/another open duplicate review case/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'keeps another open case involving only the canonical while allowing the merge' do
      third_party = create(:constituent, email: "third-#{SecureRandom.hex(3)}@example.com")
      other_case = open_case(subject: @canonical, candidate: third_party, reason: 'name_dob')

      result = merge

      assert result.success?, result.message
      assert @duplicate.reload.merged?
      assert other_case.reload.open?
      assert @canonical.reload.needs_duplicate_review?
    end

    test 'blocks merge when another open case names either participant as a candidate' do
      third_party = create(:constituent, email: "third-#{SecureRandom.hex(3)}@example.com")
      open_case(subject: third_party, candidate: @duplicate, reason: 'name_dob')

      result = merge
      assert result.failure?
      assert_match(/another open duplicate review case/i, result.message)
      assert_not @duplicate.reload.merged?
    end

    test 'resolves only the selected case, leaving a case naming neither participant untouched' do
      third_party = create(
        :constituent,
        first_name: 'Unrelated',
        last_name: "Third#{SecureRandom.hex(3)}",
        email: "third-#{SecureRandom.hex(3)}@example.com"
      )
      other_party = create(
        :constituent,
        first_name: 'Unrelated',
        last_name: "Other#{SecureRandom.hex(3)}",
        email: "other-#{SecureRandom.hex(3)}@example.com"
      )
      unrelated_case = open_case(subject: third_party, candidate: other_party, reason: 'name_dob')

      result = merge
      assert result.success?, result.message

      assert_equal 'resolved_merged', @review_case.reload.status
      assert_equal 'open', unrelated_case.reload.status, 'a case involving neither participant stays open and unresolved'
      assert_not @canonical.reload.needs_duplicate_review
    end

    test 'blocks merge when the case source is not merge eligible' do
      subject = phone_only_constituent(phone: '555-333-4444')
      candidate = create(:constituent, email: "portal3-#{SecureRandom.hex(3)}@example.com")
      non_registration_case = open_case(subject: subject, candidate: candidate, reason: 'exact_phone', source: :support_claim)

      result = merge(duplicate_review_case: non_registration_case, canonical_user: candidate, duplicate_user: subject)
      assert result.failure?
      assert_match(/not eligible/i, result.message)
      assert_not subject.reload.merged?
    end

    test 'merges an exact post-import pair and keeps the retired record out of later reconciliation' do
      canonical, duplicate = post_import_matching_pair
      review_result = DuplicateReconciliation::ReviewPairService.new(
        actor: @admin,
        first_user_id: duplicate.id,
        second_user_id: canonical.id
      ).call
      assert review_result.success?, review_result.message
      review_case = review_result.data.fetch(:duplicate_review_case)

      result = merge_post_import(review_case:, canonical:, duplicate:)

      assert result.success?, result.message
      assert duplicate.reload.merged?
      assert_equal canonical.id, duplicate.merged_into_user_id
      assert_equal 'resolved_merged', review_case.reload.status
      assert_equal 'same_person_confirmed', review_case.resolution_determination
      assert_not_includes DuplicateReconciliation::Population.new.pairs.map(&:ids), [canonical.id, duplicate.id].sort
      historical_pairs = DuplicateReconciliation::Population.new.pairs(include_historical: true)
      historical_pair = historical_pairs.find { |pair| pair.ids == [canonical.id, duplicate.id].sort }
      assert_equal :merged_retired, historical_pair.state

      DuplicateReconciliation::ReviewFlagSyncService.new(user_ids: [canonical.id, duplicate.id]).call
      assert_not canonical.reload.needs_duplicate_review
      assert_not duplicate.reload.needs_duplicate_review
    end

    test 'carries a related open post-import pair forward to the survivor instead of blocking the merge' do
      first, second = post_import_matching_pair
      third = create(
        :constituent,
        first_name: first.first_name,
        last_name: first.last_name,
        date_of_birth: first.date_of_birth,
        email: "third-#{SecureRandom.hex(5)}@example.com",
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: false
      )
      related_case = review_pair(first, second)
      selected_case = review_pair(first, third)

      result = merge_post_import(review_case: selected_case, canonical: third, duplicate: first)

      assert result.success?, result.message
      assert first.reload.merged?
      assert selected_case.reload.resolved_merged?
      assert related_case.reload.open?
      assert_equal [second.id, third.id].sort,
                   DuplicateReconciliation::Population.strict_case_pair_ids(related_case)
      assert_equal 1, result.data[:summary][:related_post_import_cases_repointed]
      assert_equal 1, Event.where(action: 'duplicate_review_case_pair_repointed').count
      assert second.reload.needs_duplicate_review?
      assert third.reload.needs_duplicate_review?
    end

    test 'supersedes a related post-import case when its survivor pair already has an open case' do
      first, second = post_import_matching_pair
      third = create(
        :constituent,
        first_name: first.first_name,
        last_name: first.last_name,
        date_of_birth: first.date_of_birth,
        email: "third-#{SecureRandom.hex(5)}@example.com",
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: false
      )
      related_case = review_pair(first, second)
      selected_case = review_pair(first, third)
      replacement_case = review_pair(second, third)

      result = merge_post_import(review_case: selected_case, canonical: third, duplicate: first)

      assert result.success?, result.message
      assert related_case.reload.resolved_superseded?
      assert_equal 'superseded_by_merge', related_case.resolution_determination
      assert_equal replacement_case.id, related_case.resolution_metadata['replacement_case_id']
      assert replacement_case.reload.open?
      assert_equal 1, result.data[:summary][:related_post_import_cases_superseded]
      assert_equal 1, Event.where(action: 'duplicate_review_case_superseded').count
    end

    test 'records one bounded repoint audit event for each related post-import case' do
      first, second = post_import_matching_pair
      third = matching_post_import_peer(first)
      fourth = matching_post_import_peer(first)
      first_related_case = review_pair(first, second)
      second_related_case = review_pair(first, third)
      selected_case = review_pair(first, fourth)

      result = merge_post_import(review_case: selected_case, canonical: fourth, duplicate: first)

      assert result.success?, result.message
      events = Event.where(action: 'duplicate_review_case_pair_repointed').order(:id)
      assert_equal 2, events.count
      assert_equal [first_related_case.id, second_related_case.id].sort,
                   events.map { |event| event.metadata['duplicate_review_case_id'] }.sort
      events.each do |event|
        assert_equal selected_case.id, event.metadata['superseding_merge_case_id']
        assert_equal [first.id, event.metadata['previous_pair_ids'].max], event.metadata['previous_pair_ids']
        assert_includes event.metadata['current_pair_ids'], fourth.id
        assert_not event.metadata.to_json.match?(/@example\.com|\d{3}-\d{3}-\d{4}/)
      end
    end

    test 'blocks a post-import case whose subject and candidate orientation is reversed' do
      canonical, duplicate = post_import_matching_pair
      review_case = open_case(
        subject: duplicate,
        candidate: canonical,
        reason: 'name_dob',
        source: :post_import_reconciliation
      )

      result = merge_post_import(review_case:, canonical:, duplicate:)

      assert result.failure?
      assert_match(/exact pair/i, result.message)
      assert_not duplicate.reload.merged?
      assert review_case.reload.open?
    end

    test 'blocks a stale post-import pair that no longer matches under lock' do
      canonical, duplicate = post_import_matching_pair
      review_result = DuplicateReconciliation::ReviewPairService.new(
        actor: @admin,
        first_user_id: canonical.id,
        second_user_id: duplicate.id
      ).call
      review_case = review_result.data.fetch(:duplicate_review_case)
      duplicate.update!(last_name: 'No longer matching')

      result = merge_post_import(review_case:, canonical:, duplicate:)

      assert result.failure?
      assert_match(/no longer has the supported/i, result.message)
      assert_not duplicate.reload.merged?
      assert review_case.reload.open?
    end

    test 'does not emit profile audit events during a successful merge' do
      profile_actions = %w[profile_updated profile_updated_by_guardian profile_created_by_admin_via_paper]
      result = nil
      assert_no_difference -> { Event.where(action: profile_actions).count } do
        result = merge
      end
      assert result.success?, result.message
      assert_equal 1, Event.where(action: 'duplicate_user_merged').count
    end

    test 'does not deduplicate audit events across two rapid merges into the same canonical' do
      result_one = merge
      assert result_one.success?, result_one.message

      second_duplicate = phone_only_constituent(phone: '555-999-1111')
      second_case = open_case(subject: second_duplicate, candidate: @canonical, reason: 'exact_phone')

      result_two = nil
      assert_difference 'Event.where(action: \'duplicate_user_merged\').count', 1 do
        result_two = merge(
          duplicate_review_case: second_case,
          duplicate_user: second_duplicate,
          contact_choices: { phone: 'canonical', phone_type: 'voice', email: 'canonical', address: 'canonical' }
        )
      end
      assert result_two.success?, result_two.message

      merged_ids = Event.where(action: 'duplicate_user_merged').pluck(Arel.sql("metadata->>'merged_user_id'"))
      assert_equal [@duplicate.id.to_s, second_duplicate.id.to_s].sort, merged_ids.sort,
                   'both merges into the same canonical must each keep their own audit event'
    end

    test 'clears the managing guardian when a transferred app was managed by the canonical' do
      app = create(:application, user: @duplicate, managing_guardian: @canonical)
      result = merge
      assert result.success?, result.message

      app.reload
      assert_equal @canonical.id, app.user_id
      assert_nil app.managing_guardian_id, 'a merged self-application must not be self-managed'
      assert app.valid?, "transferred app must stay valid: #{app.errors.full_messages.to_sentence}"
    end

    test 'clears the managing guardian when the canonical already owns an app managed by the duplicate' do
      app = create(:application, user: @canonical, managing_guardian: @duplicate)
      result = merge
      assert result.success?, result.message

      app.reload
      assert_equal @canonical.id, app.user_id
      assert_nil app.managing_guardian_id, 'guardian dropped instead of self-referencing the canonical'
      assert app.valid?, "managed app must stay valid: #{app.errors.full_messages.to_sentence}"
    end

    test 'dissolves a direct guardian relationship between the merged pair' do
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: @duplicate)
      result = merge
      assert result.success?, result.message

      assert_equal 0, GuardianRelationship.where(guardian_id: @canonical.id, dependent_id: @canonical.id).count,
                   'must not create a self guardian relationship'
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
      assert_not GuardianRelationship.exists?(guardian_id: @duplicate.id)
    end

    test 'transfers evaluations and pending print queue items but preserves historical records' do
      duplicate_app = create(:application, user: @duplicate)
      evaluation = create(:evaluation, constituent: @duplicate, application: duplicate_app)
      pending_print_item = create(:print_queue_item, :pending, constituent: @duplicate)
      printed_item = create(:print_queue_item, constituent: @duplicate)
      canceled_item = create(:print_queue_item, :canceled, constituent: @duplicate)
      notification = create(:notification, recipient: @duplicate)

      result = merge
      assert result.success?, result.message

      assert_equal @canonical.id, evaluation.reload.constituent_id,
                   'evaluation must follow the person to stay consistent with its already-transferred application'
      assert_equal @canonical.id, pending_print_item.reload.constituent_id,
                   'a still-pending print queue item needs an explicit, contactable owner'
      assert_equal @duplicate.id, printed_item.reload.constituent_id, 'a printed letter is historical and must not be rewritten'
      assert_equal @duplicate.id, canceled_item.reload.constituent_id, 'a canceled letter is historical and must not be rewritten'
      assert_equal @duplicate.id, notification.reload.recipient_id, 'notification history is preserved, not repointed'
    end

    test 'transfers guardian-as-dependent relationships without copying guardian contact' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @duplicate)
      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })
      assert result.success?, result.message
      assert GuardianRelationship.exists?(guardian_id: guardian.id, dependent_id: @canonical.id)
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
    end

    test 'preserves different dependents and moves their managing-guardian application links to the survivor' do
      canonical_dependent = create(:constituent)
      duplicate_dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: canonical_dependent)
      create(:guardian_relationship, guardian_user: @duplicate, dependent_user: duplicate_dependent)
      canonical_application = create(:application, user: canonical_dependent, managing_guardian: @canonical)
      duplicate_application = create(:application, user: duplicate_dependent, managing_guardian: @duplicate)

      result = merge

      assert result.success?, result.message
      assert_equal [canonical_dependent.id, duplicate_dependent.id].sort,
                   GuardianRelationship.where(guardian_id: @canonical.id).order(:dependent_id).pluck(:dependent_id)
      assert_equal canonical_dependent.id, canonical_application.reload.user_id
      assert_equal duplicate_dependent.id, duplicate_application.reload.user_id
      assert_equal @canonical.id, canonical_application.managing_guardian_id
      assert_equal @canonical.id, duplicate_application.managing_guardian_id
      assert_equal 1, result.data[:summary][:guardian_relationships_transferred]
      assert_equal 0, result.data[:summary][:guardian_relationships_coalesced]
    end

    test 'blocks coalescing the same dependent when relationship types conflict' do
      dependent = create(:constituent)
      create(:guardian_relationship, guardian_user: @canonical, dependent_user: dependent, relationship_type: 'Parent')
      create(:guardian_relationship, guardian_user: @duplicate, dependent_user: dependent, relationship_type: 'Legal Guardian')

      result = merge

      assert result.failure?
      assert_match(/conflicting relationship types/i, result.message)
      assert_not @duplicate.reload.merged?
      assert_equal 2, GuardianRelationship.where(dependent_id: dependent.id).count
    end

    test 'coalesces a shared guardian when duplicate dependent records are explicitly merged' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @canonical, relationship_type: 'Parent')
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @duplicate, relationship_type: 'Parent')

      result = merge

      assert result.success?, result.message
      assert_equal 1, GuardianRelationship.where(guardian_id: guardian.id, dependent_id: @canonical.id).count
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
      assert_equal 1, result.data[:summary][:guardian_relationships_coalesced]
    end

    test 'merging duplicate dependents with two active applications remains blocked' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @canonical)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @duplicate)
      create(:application, user: @canonical, status: :in_progress, managing_guardian: guardian)
      create(:application, user: @duplicate, status: :awaiting_proof, managing_guardian: guardian)

      result = merge

      assert result.failure?
      assert_match(/more than one active application/i, result.message)
      assert_not @duplicate.reload.merged?
      assert_equal 2, GuardianRelationship.where(guardian_id: guardian.id).count
    end

    test 'merging duplicate dependents preserves their different guardians on the survivor' do
      canonical_guardian = create(:constituent)
      duplicate_guardian = create(:constituent)
      canonical_relationship = create(
        :guardian_relationship,
        guardian_user: canonical_guardian,
        dependent_user: @canonical,
        relationship_type: 'Parent'
      )
      duplicate_relationship = create(
        :guardian_relationship,
        guardian_user: duplicate_guardian,
        dependent_user: @duplicate,
        relationship_type: 'Legal Guardian'
      )

      result = merge

      assert result.success?, result.message
      assert_equal @canonical.id, canonical_relationship.reload.dependent_id
      assert_equal @canonical.id, duplicate_relationship.reload.dependent_id
      assert_equal [canonical_guardian.id, duplicate_guardian.id].sort,
                   GuardianRelationship.where(dependent_id: @canonical.id).order(:guardian_id).pluck(:guardian_id)
      assert_equal 'Parent', canonical_relationship.relationship_type
      assert_equal 'Legal Guardian', duplicate_relationship.relationship_type
      assert_not GuardianRelationship.exists?(dependent_id: @duplicate.id)
    end

    test 'guardian-first and dependent-first merges converge on the same family and application ownership' do
      guardian_first = merge_family_in_order(:guardian_first)
      dependent_first = merge_family_in_order(:dependent_first)

      expected = {
        relationships: 1,
        guardian_duplicate_retired: true,
        dependent_duplicate_retired: true,
        application_owned_by_dependent_survivor: true,
        application_managed_by_guardian_survivor: true
      }
      assert_equal expected, guardian_first
      assert_equal expected, dependent_first
    end

    test 'retirement clears all primary contact truth and invalidates an outstanding reset token' do
      retiring_email = "retiring-#{SecureRandom.hex(4)}@example.com"
      retiring_phone = @duplicate.phone
      @duplicate.update!(email: retiring_email, phone_type: 'text')
      password_reset_token = @duplicate.generate_token_for(:password_reset)

      result = merge(
        contact_choices: { phone: 'canonical', phone_type: nil, email: 'canonical', address: 'canonical' }
      )

      assert result.success?, result.message
      @duplicate.reload
      assert_nil @duplicate.email
      assert_nil @duplicate.phone
      assert_nil @duplicate.phone_type
      assert_not User.exists_with_email?(retiring_email)
      assert_not User.exists_with_phone?(retiring_phone)
      assert_nil User.find_by_token_for(:password_reset, password_reset_token)
    end

    # The retirement case above covers the duplicate. This covers the survivor, which is the
    # dangerous half: a merge that replaces the canonical's phone is the admin declaring the old
    # number is not this person's, and an account-access reset link already texted to that number
    # must stop working. Reset authority is revoked through the token fingerprint, not through
    # lock ordering at issuance -- issuing the link before the merge was legitimate at the time,
    # so no amount of locking the lookup would invalidate it afterwards.
    test 'discarding the canonical phone invalidates a reset link already sent to that number' do
      @canonical.update!(phone: '555-867-5309', phone_type: 'voice')
      discarded_phone = @canonical.phone
      token_texted_to_discarded_phone = @canonical.generate_token_for(:password_reset)

      result = merge(contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' })

      assert result.success?, result.message
      @canonical.reload
      assert_equal '555-777-8888', @canonical.phone, 'the merge moved the duplicate phone onto the survivor'
      assert_not_equal discarded_phone, @canonical.phone
      assert @canonical.real_email?, 'survivor keeps login email, so the digest and email halves are unchanged'
      assert_nil User.find_by_token_for(:password_reset, token_texted_to_discarded_phone),
                 'a reset link delivered to the discarded number must not survive the merge'
    end

    test 'keeping the canonical phone leaves an outstanding reset link usable' do
      @canonical.update!(phone: '555-867-5309', phone_type: 'voice')
      token = @canonical.generate_token_for(:password_reset)

      result = merge(contact_choices: { phone: 'canonical', phone_type: 'voice', email: 'canonical', address: 'canonical' })

      assert result.success?, result.message
      assert_equal @canonical.id, User.find_by_token_for(:password_reset, token)&.id,
                   'contact authority did not change, so the link must still work'
    end

    test 'clears a stale survivor phone type when the selected surviving phone is blank' do
      @canonical.update!(phone: nil, phone_type: 'voice')

      result = merge(
        contact_choices: { phone: 'canonical', phone_type: nil, email: 'canonical', address: 'canonical' }
      )

      assert result.success?, result.message
      assert_nil @canonical.reload.phone
      assert_nil @canonical.phone_type
    end

    # portal_creation_key identifies one portal request inside one guardian's namespace, and the
    # partial unique index is scoped (guardian_id, portal_creation_key) to match. The two repoints
    # in transfer_guardian_relationships! are therefore asymmetric, and both directions are pinned
    # here: a wrong choice either strands a key under an account that never made the request, or
    # discards replay history that is still true.

    test 'retiring a guardian clears the replay keys on the relationships it transfers' do
      dependent = create(:constituent)
      key = SecureRandom.hex(16)
      relationship = GuardianRelationship.create!(guardian_user: @duplicate, dependent_user: dependent,
                                                  relationship_type: 'Parent', portal_creation_key: key,
                                                  portal_creation_fingerprint: fake_fingerprint)

      result = merge
      assert result.success?, result.message

      relationship.reload
      assert_equal @canonical.id, relationship.guardian_id, 'the relationship must transfer'
      assert_nil relationship.portal_creation_key,
                 "the retired guardian's request namespace ends with it, so its keys must not become the canonical guardian's"
      assert_nil relationship.portal_creation_fingerprint,
                 'the pair clears together; a stranded fingerprint would violate the pair constraint'
    end

    # The same key may legitimately exist under the canonical guardian already. Carrying the retired
    # guardian's copy across unchanged would collide on the scoped index; clearing it must let the
    # merge complete.
    test 'a key already held by the canonical guardian does not block the merge' do
      key = SecureRandom.hex(16)
      GuardianRelationship.create!(guardian_user: @canonical, dependent_user: create(:constituent),
                                   relationship_type: 'Parent', portal_creation_key: key,
                                   portal_creation_fingerprint: fake_fingerprint)
      transferring = GuardianRelationship.create!(guardian_user: @duplicate, dependent_user: create(:constituent),
                                                  relationship_type: 'Parent', portal_creation_key: key,
                                                  portal_creation_fingerprint: fake_fingerprint)

      result = merge
      assert result.success?, result.message

      assert_nil transferring.reload.portal_creation_key
      assert_equal 1, GuardianRelationship.where(guardian_id: @canonical.id, portal_creation_key: key).count
    end

    test 'retiring a dependent preserves the replay pair on the relationships it transfers' do
      guardian = create(:constituent)
      key = SecureRandom.hex(16)
      fingerprint = fake_fingerprint
      relationship = GuardianRelationship.create!(guardian_user: guardian, dependent_user: @duplicate,
                                                  relationship_type: 'Parent', portal_creation_key: key,
                                                  portal_creation_fingerprint: fingerprint)

      result = merge
      assert result.success?, result.message

      relationship.reload
      assert_equal @canonical.id, relationship.dependent_id, 'the relationship must transfer'
      assert_equal key, relationship.portal_creation_key,
                   'the guardian and their request namespace are unchanged, so the key is still true'
      assert_equal fingerprint, relationship.portal_creation_fingerprint,
                   'the pair moves together: a preserved key with a cleared fingerprint would break the pair constraint'
    end

    test 'coalescing duplicate dependents preserves the sole portal replay pair' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @canonical, relationship_type: 'Parent')
      key = SecureRandom.uuid
      fingerprint = fake_fingerprint
      keyed_relationship = GuardianRelationship.create!(
        guardian_user: guardian,
        dependent_user: @duplicate,
        relationship_type: 'Parent',
        portal_creation_key: key,
        portal_creation_fingerprint: fingerprint
      )

      result = merge

      assert result.success?, result.message
      keyed_relationship.reload
      assert_equal @canonical.id, keyed_relationship.dependent_id
      assert_equal key, keyed_relationship.portal_creation_key
      assert_equal fingerprint, keyed_relationship.portal_creation_fingerprint
      assert_equal 1, GuardianRelationship.where(guardian_id: guardian.id, dependent_id: @canonical.id).count
    end

    test 'blocks coalescing two separately replay-protected dependent relationships' do
      guardian = create(:constituent)
      GuardianRelationship.create!(
        guardian_user: guardian,
        dependent_user: @canonical,
        relationship_type: 'Parent',
        portal_creation_key: SecureRandom.uuid,
        portal_creation_fingerprint: fake_fingerprint
      )
      GuardianRelationship.create!(
        guardian_user: guardian,
        dependent_user: @duplicate,
        relationship_type: 'Parent',
        portal_creation_key: SecureRandom.uuid,
        portal_creation_fingerprint: fake_fingerprint
      )

      result = merge

      assert result.failure?
      assert_match(/separately recorded portal links/i, result.message)
      assert_not @duplicate.reload.merged?
      assert_equal 2, GuardianRelationship.where(guardian_id: guardian.id).count
    end

    private

    # The replay pair is meaningless split, and a check constraint enforces that, so fixtures that
    # set a key directly must supply a fingerprint too. The value is opaque here: these tests are
    # about the key's scope and the merge repoints, not about fingerprint comparison.
    def fake_fingerprint
      "v1:#{SecureRandom.hex(32)}"
    end

    def merge_family_in_order(order)
      guardian_survivor = create(:constituent)
      guardian_duplicate = create(:constituent)
      dependent_survivor = create(:constituent)
      dependent_duplicate = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian_survivor, dependent_user: dependent_survivor)
      create(:guardian_relationship, guardian_user: guardian_duplicate, dependent_user: dependent_duplicate)
      application = create(:application, :approved, user: dependent_duplicate, managing_guardian: guardian_duplicate)

      guardian_case = open_case(
        subject: guardian_duplicate,
        candidate: guardian_survivor,
        reason: 'name_dob'
      )
      dependent_case = open_case(
        subject: dependent_duplicate,
        candidate: dependent_survivor,
        reason: 'name_dob'
      )
      merges = {
        guardian_first: [
          [guardian_case, guardian_survivor, guardian_duplicate],
          [dependent_case, dependent_survivor, dependent_duplicate]
        ],
        dependent_first: [
          [dependent_case, dependent_survivor, dependent_duplicate],
          [guardian_case, guardian_survivor, guardian_duplicate]
        ]
      }.fetch(order)

      merges.each do |review_case, canonical, duplicate|
        result = merge_independent_pair(review_case:, canonical:, duplicate:)
        assert result.success?, "#{order} merge failed: #{result.message}"
      end

      {
        relationships: GuardianRelationship.where(
          guardian_id: guardian_survivor.id,
          dependent_id: dependent_survivor.id
        ).count,
        guardian_duplicate_retired: guardian_duplicate.reload.merged?,
        dependent_duplicate_retired: dependent_duplicate.reload.merged?,
        application_owned_by_dependent_survivor: application.reload.user_id == dependent_survivor.id,
        application_managed_by_guardian_survivor: application.managing_guardian_id == guardian_survivor.id
      }
    end

    def merge_independent_pair(review_case:, canonical:, duplicate:)
      DuplicateMergeService.new(
        actor: @admin,
        duplicate_review_case: review_case,
        canonical_user: canonical,
        duplicate_user: duplicate,
        same_person_confirmed: true,
        rationale: 'confirmed same person while testing family merge order',
        reason_codes: %w[name_dob],
        contact_choices: {
          phone: 'canonical',
          phone_type: canonical.phone_type,
          email: 'canonical',
          address: 'canonical'
        },
        delivery_choice: 'canonical'
      ).call
    end

    def merge(**overrides)
      defaults = {
        actor: @admin,
        duplicate_review_case: @review_case,
        canonical_user: @canonical,
        duplicate_user: @duplicate,
        same_person_confirmed: true,
        rationale: 'confirmed same person via support call',
        reason_codes: %w[exact_phone],
        contact_choices: { phone: 'duplicate', phone_type: 'voice', email: 'canonical', address: 'canonical' },
        delivery_choice: 'canonical'
      }
      DuplicateMergeService.new(**defaults, **overrides).call
    end

    def phone_only_constituent(phone:)
      Current.paper_context = true
      create(:constituent, email: nil, phone: phone, communication_preference: :letter)
    ensure
      Current.reset
    end

    def post_import_matching_pair
      shared_attributes = {
        first_name: 'PostImport',
        last_name: "Merge#{SecureRandom.hex(4)}",
        date_of_birth: Date.new(1977, 11, 3),
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: false
      }
      canonical = create(:constituent, **shared_attributes, email: "canonical-#{SecureRandom.hex(5)}@example.com")
      duplicate = create(:constituent, **shared_attributes, email: "duplicate-#{SecureRandom.hex(5)}@example.com")
      [canonical, duplicate]
    end

    def matching_post_import_peer(user)
      create(
        :constituent,
        first_name: user.first_name,
        last_name: user.last_name,
        date_of_birth: user.date_of_birth,
        email: "peer-#{SecureRandom.hex(5)}@example.com",
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: false
      )
    end

    def merge_post_import(review_case:, canonical:, duplicate:)
      DuplicateMergeService.new(
        actor: @admin,
        duplicate_review_case: review_case,
        canonical_user: canonical,
        duplicate_user: duplicate,
        same_person_confirmed: true,
        rationale: 'confirmed same imported person',
        reason_codes: %w[name_dob admin_reviewed],
        contact_choices: { phone: 'canonical', email: 'canonical', address: 'canonical' },
        delivery_choice: 'canonical'
      ).call
    end

    def review_pair(first, second)
      result = DuplicateReconciliation::ReviewPairService.new(
        actor: @admin,
        first_user_id: first.id,
        second_user_id: second.id
      ).call
      assert result.success?, result.message
      result.data.fetch(:duplicate_review_case)
    end

    # Defaults to registration_soft_match; pass an explicit source for cases that exist only
    # to exercise the competing-open-case blocker rather than being merged themselves.
    def open_case(subject:, candidate:, reason:, source: :registration_soft_match)
      review_case = DuplicateReviewCase.create!(
        source: source,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => [reason] },
        opened_at: Time.current,
        status: :open
      )
      review_case.duplicate_review_case_candidates.create!(candidate_user: candidate, match_reason: reason, snapshot: {})
      review_case
    end
  end
end
