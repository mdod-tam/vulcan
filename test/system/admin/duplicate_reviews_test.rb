# frozen_string_literal: true

require 'application_system_test_case'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  class DuplicateReviewsTest < ApplicationSystemTestCase
    include SystemTestEvidence

    setup do
      @admin = create(:admin)
      @subject = create(
        :constituent,
        first_name: 'Portal',
        last_name: 'Registrant',
        email: "portal-registrant-#{SecureRandom.hex(3)}@example.com",
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: true
      )
      @candidate = create(
        :constituent,
        first_name: 'Existing',
        last_name: 'Account',
        email: "existing-account-#{SecureRandom.hex(3)}@example.com",
        phone: '410-555-0198',
        phone_type: 'text'
      )
      @review_case = DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: @subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
      @review_case.duplicate_review_case_candidates.create!(
        candidate_user: @candidate,
        match_reason: 'name_dob',
        snapshot: {}
      )

      system_test_sign_in(@admin)
    end

    # A non-merge resolution means exactly one thing -- staff decided these are different people --
    # so the five-value determination control was offering a choice that did not exist. Resolving
    # recomputes two independent effects from remaining open cases: the submission gate releases
    # when no open registration soft-match case remains, and the review flag clears when no open
    # case of any source remains -- taking the subject off the queue badges staff rely on. Only a
    # completed identity decision may trigger either, so the outcome is server-owned and stated
    # plainly.
    test 'the resolve form states the fixed identity outcome instead of offering a choice' do
      visit admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'

      assert_no_selector 'select[name=determination]'
      # The action is server-owned, so the form offers no action control at all.
      within 'form[action$="/resolve"]' do
        assert_no_selector 'input[type=radio][name=resolution_action]'
        assert_no_selector 'legend', text: 'Action'
        assert_no_text 'Evidence / reason codes'
        assert_no_selector 'input[name="reason_codes[]"]'
        assert_field 'Why these records are different people (required)'
      end
      within '#identity-outcome' do
        assert_text 'Identity outcome: Keep records separate'
        assert_text 'represent different people'
        assert_text 'If they are the same person, merge them instead'
        assert_text 'leave this case open'
      end
      assert_no_text 'Every resolution records the determination and rationale'

      take_evidence_screenshot('duplicate-review-resolve-form-server-owned-outcome',
                               full: true, html: true)
    end

    # The resolution summary shows the outcome and the determination side by side, so the two must
    # agree. This is the state an admin is left looking at after deciding, and it is the only place
    # the status label is read back to them.
    test 'the resolved summary reports an outcome that agrees with the determination' do
      visit admin_duplicate_review_path(@review_case)

      within 'form[action$="/resolve"]' do
        fill_in 'rationale', with: 'confirmed these are different people'
        click_button 'Resolve case'
      end

      visit admin_duplicate_review_path(@review_case)
      within '[data-testid="resolution-summary"]' do
        assert_text 'Resolved without merge'
        assert_text 'Keep separate'
        assert_no_text 'Ignored'
      end
      assert_no_selector 'form[action$="/resolve"]'

      take_evidence_screenshot('duplicate-review-resolved-summary', full: true, html: true)
    end

    # The rollover guard has its own visible state. A page rendered before this shipped still has the
    # old determination select, so submitting it must not resolve the case under an intent the admin
    # no longer expressed. The request test proves the server refuses; this proves the admin can see
    # why and is left on a usable form.
    test 'a stale determination is refused with a visible alert and the case stays open' do
      visit admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'

      # Reconstruct the pre-5c-1 form: inject the determination control the old page carried.
      page.execute_script(<<~JS)
        const form = document.querySelector('form[action$="/resolve"]');
        const select = document.createElement('select');
        select.name = 'determination';
        select.innerHTML = '<option value="needs_more_information" selected>Needs more information</option>';
        form.appendChild(select);
      JS

      # Scoped: the merge form carries its own rationale field.
      within 'form[action$="/resolve"]' do
        fill_in 'rationale', with: 'still gathering documents'
        click_button 'Resolve case'
      end

      assert_text 'This form was out of date, so we reloaded the case.'
      assert_selector '[data-testid="duplicate-review-detail"]', text: 'Duplicate Review Case'
      assert @review_case.reload.open?, 'a stale submission must not resolve the case'
      assert_nil @review_case.resolved_at
      # The admin is left able to act, on the current form rather than the stale one.
      assert_selector '#identity-outcome', text: 'Keep records separate'
      assert_no_selector 'select[name=determination]'

      take_evidence_screenshot('duplicate-review-stale-determination-refused', full: true, html: true)
    end

    test 'admin merge form keeps login authority fixed and gates conditional phone type' do
      date_of_birth = Date.new(1985, 4, 12)
      @subject.update_columns(created_at: 2.years.ago, last_sign_in_at: 3.days.ago, date_of_birth:)
      @candidate.update_columns(created_at: 1.year.ago, last_sign_in_at: 1.day.ago, date_of_birth:)
      @subject.update!(physical_address_1: '101 Harbor Street', city: 'Baltimore', state: 'MD', zip_code: '21201')
      @candidate.update!(physical_address_1: '303 Harbor Street', city: 'Towson', state: 'MD', zip_code: '21204')
      create(:application, :approved, user: @candidate)

      visit admin_duplicate_reviews_path
      assert_selector '[data-testid="duplicate-review-queue"]'
      within "[data-testid='duplicate-review-case-row'][data-case-id='#{@review_case.id}']" do
        assert_text "Duplicate review case ##{@review_case.id}"
        assert_text '2 records in this case'
        assert_selector '[data-testid="open-case-participant"]', count: 2
        assert_text "Constituent ID #{@subject.id}"
        assert_text "Constituent ID #{@candidate.id}"
      end
      take_evidence_screenshot('duplicate-review-queue-current', full: true, html: true)

      click_link 'Continue review'
      assert_current_path admin_duplicate_review_path(@review_case)
      assert_selector '[data-testid="duplicate-review-detail"]'
      assert_text 'Record comparison'
      assert_no_text 'Subject record'
      within '[data-testid="candidate-comparison"]' do
        assert_selector '[data-testid="record-facts"]', count: 2
        assert_selector '[data-testid="record-date-of-birth"]', text: '04/12/1985', count: 2
        assert_text "Constituent ID #{@subject.id}"
        assert_text "Constituent ID #{@candidate.id}"
        assert_text 'Newer record', count: 1
        assert_text 'Most recent login', count: 1
        assert_text 'No applications', count: 1
        assert_text '1 application', count: 1
        assert_text 'Approved'
      end
      find('summary', text: 'Merge these two records').click

      form_selector = 'form[data-testid="duplicate-merge-form"]'
      assert_selector form_selector
      assert_no_selector "#{form_selector} input[type='radio'][name='contact[email]']"

      prefix = "duplicate-review-#{@review_case.id}-candidate-#{@candidate.id}"
      within(form_selector) do
        assert_text 'Canonical record and login identity'
        assert_text "Login email: #{@subject.email}"
        assert_text "Login email: #{@candidate.email}"
        assert_text 'Newer record', count: 1
        assert_text 'Most recent login', count: 1
        assert_text 'Last successful login:', count: 2
        assert_text @subject.last_sign_in_at.strftime('%b %d, %Y at %I:%M %p')
        assert_text @candidate.last_sign_in_at.strftime('%b %d, %Y at %I:%M %p')
        within '[data-testid="shared-merge-facts"]' do
          assert_text 'Date of birth'
          assert_text '04/12/1985'
          assert_text 'Official-notice delivery route'
          assert_text 'Email'
          assert_text 'Both records agree', count: 2
        end
        assert_no_selector 'input[type="radio"][name="delivery_user_id"]'
        assert_text "#{@subject.full_name} (Constituent ID #{@subject.id})"
        assert_text "#{@candidate.full_name} (Constituent ID #{@candidate.id})"
        assert_no_text "subject ##{@subject.id}", exact: false
        assert_no_text "candidate ##{@candidate.id}", exact: false
        assert_no_selector 'input[name="reason_codes[]"]'
        assert_text 'Match evidence recorded with this case'
        assert_text 'This explains why the comparison was opened; it does not by itself prove the records are the same person.'
        assert_field 'Why these records are the same person (required)'
        choose "#{prefix}-canonical-#{@candidate.id}"
        choose "#{prefix}-phone-source-#{@candidate.id}"
        choose "#{prefix}-address-source-#{@candidate.id}"
        fill_in "#{prefix}-rationale", with: 'Identity verified from the registration evidence and support call.'
        check "#{prefix}-same-person-confirmed"

        assert_selector "##{prefix}-phone-type[required][aria-required='true']"
        assert_selector "input[type='submit'][disabled]"

        # Each decision group carries its own accessible name, and the gate says which one is
        # still outstanding rather than only that something is.
        assert_selector 'fieldset > legend', text: 'Phone'
        assert_selector 'fieldset > legend', text: 'Address'
        assert_selector '[data-final-submit-gate-target="status"]', text: 'Still needed: Phone type.'
      end
      take_evidence_screenshot('duplicate-merge-real-phone-type-required', full: true, html: true)

      within(form_selector) do
        select 'Voice', from: "#{prefix}-phone-type"
        assert_selector "input[type='submit']:not([disabled])"
      end
      take_evidence_screenshot('duplicate-merge-ready-with-phone-type', full: true, html: true)

      within(form_selector) do
        choose "#{prefix}-phone-source-#{@subject.id}"
        # A control whose value is cleared on every update must not stay operable, so no real
        # phone surviving disables it outright rather than leaving a selection the gate would
        # silently discard. (A CSS `find` still locates it; only find_field filters on disabled.)
        phone_type = find("##{prefix}-phone-type")
        assert_equal 'false', phone_type['aria-required']
        assert_not phone_type[:required]
        assert phone_type.disabled?, 'phone type must not remain operable when no real phone survives'
        assert_equal '', phone_type.value
        assert_selector "input[type='submit']:not([disabled])"
      end
      take_evidence_screenshot('duplicate-merge-blank-phone-clears-phone-type', full: true, html: true)
    end

    test 'admin submits differing facts and the selected values survive the merge' do
      date_of_birth = Date.new(1985, 4, 12)
      @subject.update!(
        date_of_birth:,
        physical_address_1: '101 Harbor Street',
        city: 'Baltimore',
        state: 'MD',
        zip_code: '21201',
        communication_preference: :letter
      )
      @candidate.update!(
        date_of_birth:,
        physical_address_1: '303 Harbor Street',
        physical_address_2: 'Suite 4',
        city: 'Towson',
        state: 'MD',
        zip_code: '21204',
        communication_preference: :email
      )
      candidate_application = create(:application, :approved, user: @candidate)
      subject_email = @subject.email
      candidate_phone = @candidate.phone

      visit admin_duplicate_review_path(@review_case)
      find('summary', text: 'Merge these two records').click

      prefix = "duplicate-review-#{@review_case.id}-candidate-#{@candidate.id}"
      assert_difference "Event.where(action: 'duplicate_user_merged').count", 1 do
        within 'form[data-testid="duplicate-merge-form"]' do
          choose "#{prefix}-canonical-#{@subject.id}"
          choose "#{prefix}-phone-source-#{@candidate.id}"
          select 'Text', from: "#{prefix}-phone-type"
          choose "#{prefix}-address-source-#{@candidate.id}"
          choose "#{prefix}-delivery-source-#{@candidate.id}"
          fill_in "#{prefix}-rationale", with: 'Verified one identity and selected the current contact facts.'
          check "#{prefix}-same-person-confirmed"
          accept_confirm { click_button 'Merge records' }
        end
      end

      assert_current_path admin_user_path(@subject)
      assert_text 'Duplicate record merged into the canonical account.'

      @subject.reload
      assert_equal subject_email, @subject.email, 'the canonical login identity must stay together'
      assert_equal candidate_phone, @subject.phone
      assert_equal 'text', @subject.phone_type
      assert_equal '303 Harbor Street', @subject.physical_address_1
      assert_equal 'Suite 4', @subject.physical_address_2
      assert_equal 'Towson', @subject.city
      assert_equal 'MD', @subject.state
      assert_equal '21204', @subject.zip_code
      assert_equal 'email', @subject.communication_preference
      assert_equal @subject.id, candidate_application.reload.user_id

      @candidate.reload
      assert @candidate.merged?
      assert_equal @subject.id, @candidate.merged_into_user_id
      assert_equal 'resolved_merged', @review_case.reload.status
      take_evidence_screenshot('duplicate-merge-differing-facts-submitted', full: true, html: true)
    end

    test 'shared phone type and account history stay with the canonical choices' do
      @subject.update!(phone: '410-555-0101', phone_type: 'voice')
      @candidate.update!(phone: '410-555-0103', phone_type: 'voice')
      @subject.update_columns(created_at: 2.years.ago, last_sign_in_at: 3.days.ago)
      @candidate.update_columns(created_at: 1.year.ago, last_sign_in_at: 1.day.ago)

      visit admin_duplicate_review_path(@review_case)
      find('summary', text: 'Merge these two records').click

      within 'form[data-testid="duplicate-merge-form"]' do
        within '[data-testid="shared-merge-facts"]' do
          assert_selector '[data-testid="shared-merge-fact"][data-fact="phone_type"]',
                          text: /Voice.*Both records agree/m
        end
        assert_no_selector 'select[name="contact[phone_type]"]'
        assert_text 'Newer record', count: 1
        assert_text 'Most recent login', count: 1
        assert_text 'Last successful login:', count: 2
        assert_text @subject.last_sign_in_at.strftime('%b %d, %Y at %I:%M %p')
        assert_text @candidate.last_sign_in_at.strftime('%b %d, %Y at %I:%M %p')
        assert_no_selector 'input[name="reason_codes[]"]'
        assert_field 'Why these records are the same person (required)'
      end

      take_evidence_screenshot('duplicate-merge-shared-phone-type-and-record-history', full: true, html: true)
    end

    test 'admin opens and resolves one imported matching pair from the existing queue' do
      first, second = create_unreviewed_pair

      visit admin_duplicate_reviews_path
      match_group = find('[data-testid="unreviewed-match-group"]', text: first.full_name)
      within match_group do
        assert_text first.full_name
        assert_text second.full_name
        assert_text 'Email present: Yes', count: 2
        assert_text 'Applications: None', count: 2
        assert_text '2 records · 1 comparison remaining'
        assert_no_text 'Review flag:'
        assert_no_text first.email
        assert_no_text second.email
        assert_no_text first.date_of_birth.to_s
      end
      take_evidence_screenshot('duplicate-post-import-pair-queue-entry', full: true, html: true)

      within match_group do
        click_button 'Compare these two records'
      end

      review_case = DuplicateReviewCase.where(source: :post_import_reconciliation).order(:id).last
      assert_current_path admin_duplicate_review_path(review_case)
      assert_text 'Post-import reconciliation'
      assert_text 'Name and date of birth match'
      assert_text 'Resolve without merging'
      find('summary', text: 'Merge these two records').click
      assert_selector 'form[data-testid="duplicate-merge-form"]'
      take_evidence_screenshot('duplicate-post-import-pair-detail-actions', full: true, html: true)

      within 'form[action$="/resolve"]' do
        fill_in 'rationale', with: 'Confirmed these imported records belong to different people.'
        click_button 'Resolve case'
      end

      assert_current_path admin_duplicate_reviews_path
      assert_text 'Duplicate review case resolved.'
      assert_no_selector '[data-testid="unreviewed-match-group"]', text: first.full_name
      assert_equal 'keep_separate', review_case.reload.resolution_determination
      assert_not first.reload.needs_duplicate_review
      assert_not second.reload.needs_duplicate_review
      take_evidence_screenshot('duplicate-post-import-pair-resolved-queue', full: true, html: true)
    end

    test 'stale imported pair entry returns to the queue with a visible refusal and no side effects' do
      first, second = create_unreviewed_pair

      visit admin_duplicate_reviews_path
      match_group = find('[data-testid="unreviewed-match-group"]', text: first.full_name)
      second.update!(last_name: 'Changed after queue render')

      assert_no_difference ['DuplicateReviewCase.count', 'Event.count'] do
        within match_group do
          click_button 'Compare these two records'
        end
      end

      assert_current_path admin_duplicate_reviews_path
      assert_text 'These records no longer form a current supported name-and-date-of-birth pair.'
      assert_not first.reload.needs_duplicate_review
      assert_not second.reload.needs_duplicate_review
      take_evidence_screenshot('duplicate-post-import-pair-stale-refusal', full: true, html: true)
    end

    test 'admin merges one imported matching pair through the existing merge workflow' do
      first, second = create_unreviewed_pair

      visit admin_duplicate_reviews_path
      within('[data-testid="unreviewed-match-group"]', text: first.full_name) do
        click_button 'Compare these two records'
      end

      review_case = DuplicateReviewCase.where(source: :post_import_reconciliation).order(:id).last
      assert_current_path admin_duplicate_review_path(review_case)
      find('summary', text: 'Merge these two records').click

      canonical, duplicate = [first, second].sort_by(&:id)
      prefix = "duplicate-review-#{review_case.id}-candidate-#{duplicate.id}"
      within 'form[data-testid="duplicate-merge-form"]' do
        assert_selector '[data-testid="shared-merge-fact"]', count: 4
        assert_no_selector 'input[type="radio"][name="contact[phone_user_id]"]'
        assert_no_selector 'input[type="radio"][name="contact[address_user_id]"]'
        assert_no_selector 'input[type="radio"][name="delivery_user_id"]'
        choose "#{prefix}-canonical-#{canonical.id}"
        fill_in "#{prefix}-rationale", with: 'Confirmed both imported records belong to the same person.'
        check "#{prefix}-same-person-confirmed"
        accept_confirm { click_button 'Merge records' }
      end

      assert_current_path admin_user_path(canonical)
      assert_text 'Duplicate record merged into the canonical account.'
      assert duplicate.reload.merged?
      assert_equal canonical.id, duplicate.merged_into_user_id
      assert_equal 'resolved_merged', review_case.reload.status
      take_evidence_screenshot('duplicate-post-import-pair-merged-survivor', full: true, html: true)

      visit admin_duplicate_reviews_path
      assert_no_selector '[data-testid="unreviewed-match-group"]', text: first.full_name
      take_evidence_screenshot('duplicate-post-import-pair-merged-queue', full: true, html: true)
    end

    test 'guardian merge names affected dependents and carries another open group comparison to the survivor' do
      first, second, third = create_unreviewed_group(count: 3)
      dependent = create(
        :constituent,
        first_name: 'Jamie',
        last_name: first.last_name,
        date_of_birth: Date.new(2014, 6, 5)
      )
      create(:guardian_relationship, guardian_user: first, dependent_user: dependent, relationship_type: 'Parent')
      dependent_application = create(:application, :approved, user: dependent, managing_guardian: first)

      related_result = DuplicateReconciliation::ReviewPairService.new(
        actor: @admin,
        first_user_id: first.id,
        second_user_id: second.id
      ).call
      selected_result = DuplicateReconciliation::ReviewPairService.new(
        actor: @admin,
        first_user_id: first.id,
        second_user_id: third.id
      ).call
      assert related_result.success?, related_result.message
      assert selected_result.success?, selected_result.message
      related_case = related_result.data.fetch(:duplicate_review_case)
      selected_case = selected_result.data.fetch(:duplicate_review_case)

      visit admin_duplicate_review_path(selected_case)
      find('summary', text: 'Merge these two records').click

      prefix = "duplicate-review-#{selected_case.id}-candidate-#{third.id}"
      within 'form[data-testid="duplicate-merge-form"]' do
        within '[data-testid="merge-relationship-impact"]' do
          assert_text 'Relationships affected'
          assert_text "#{first.full_name} (Constituent ID #{first.id})"
          assert_text "#{dependent.full_name} (Constituent ID #{dependent.id})"
          assert_text 'Parent'
          assert_text "##{dependent_application.id} Approved"
          assert_text "#{third.full_name} (Constituent ID #{third.id})"
          assert_text 'Has no dependents.'
          assert_text 'will be linked to the surviving record'
          assert_text '1 application will remain attached to this dependent'
          assert_text 'Different dependent records and their applications are not merged by this action.'
        end

        choose "#{prefix}-canonical-#{third.id}"
        fill_in "#{prefix}-rationale", with: 'Confirmed the guardian records represent the same person.'
        check "#{prefix}-same-person-confirmed"
      end
      take_evidence_screenshot('duplicate-merge-dependent-impact-and-related-case', full: true, html: true)

      within 'form[data-testid="duplicate-merge-form"]' do
        accept_confirm { click_button 'Merge records' }
      end

      assert_current_path admin_user_path(third)
      assert_text 'Duplicate record merged into the canonical account.'
      assert first.reload.merged?
      assert_equal third.id, first.merged_into_user_id
      assert GuardianRelationship.exists?(guardian_id: third.id, dependent_id: dependent.id)
      assert_equal dependent.id, dependent_application.reload.user_id
      assert_equal third.id, dependent_application.managing_guardian_id
      assert selected_case.reload.resolved_merged?
      assert related_case.reload.open?
      assert_equal [second.id, third.id].sort,
                   DuplicateReconciliation::Population.strict_case_pair_ids(related_case)

      visit admin_duplicate_reviews_path
      assert_no_text 'Another open duplicate review case references one of these records'
      within "[data-testid='duplicate-review-case-row'][data-case-id='#{related_case.id}']" do
        assert_selector '[data-testid="open-case-participant"]', count: 2
        assert_text "Constituent ID #{second.id}"
        assert_text "Constituent ID #{third.id}"
        assert_no_text "Constituent ID #{first.id}"
      end
      assert_no_selector '[data-testid="unreviewed-match-group"]', text: first.full_name
      take_evidence_screenshot('duplicate-merge-related-case-carried-forward', full: true, html: true)
    end

    test 'queue groups a three-record match and progressively discloses exact pair actions' do
      members = create_unreviewed_group(count: 3)
      selected_ids = members.first(2).map(&:id).sort

      visit admin_duplicate_reviews_path
      match_group = find('[data-testid="unreviewed-match-group"]', text: members.first.full_name)

      within match_group do
        assert_text '3 records · 3 comparisons remaining'
        assert_selector '[data-testid="match-group-member"]', count: 3
        assert_selector '[data-testid="next-pair-action"]',
                        text: "Next pair: Constituent IDs #{selected_ids.first} and #{selected_ids.second}"
        assert_button 'Compare next'
        assert_selector 'summary', text: 'Show pairings', count: 1
        assert_no_selector '[data-testid="match-group-review-disclosure"][open]', visible: :all
        assert_selector '[data-testid="unreviewed-pair-action"]', count: 3, visible: :all
        assert_no_text 'Review flag:'

        members.each do |member|
          assert_selector "[data-testid='match-group-member'][data-constituent-id='#{member.id}']", count: 1
        end
      end

      take_evidence_screenshot('duplicate-post-import-three-record-group', full: true, html: true)

      within match_group do
        find('summary', text: 'Show pairings').click
        assert_selector '[data-testid="match-group-review-disclosure"][open]', visible: :all
        assert_text 'Choose two records to compare'
        assert_selector '[data-testid="unreviewed-pair-action"]', count: 3

        members.map(&:id).sort.combination(2).each do |first_id, second_id|
          assert_selector "input[type='submit'][aria-label='Compare records: constituent records #{first_id} and #{second_id}']",
                          count: 1
        end
      end

      take_evidence_screenshot('duplicate-post-import-three-record-pair-picker', full: true, html: true)

      within match_group do
        find("input[aria-label='Compare records: constituent records #{selected_ids.first} and #{selected_ids.second}']").click
      end

      review_case = DuplicateReviewCase.where(source: :post_import_reconciliation).order(:id).last
      assert_current_path admin_duplicate_review_path(review_case)
      assert_equal selected_ids, DuplicateReconciliation::Population.strict_case_pair_ids(review_case)
      assert_text 'Post-import reconciliation'
      take_evidence_screenshot('duplicate-post-import-three-record-selected-pair', full: true, html: true)

      click_link 'Back to queue'
      assert_current_path admin_duplicate_reviews_path
      within('[data-testid="duplicate-review-case-row"]', text: members.first.full_name) do
        assert_text 'Post-import reconciliation'
        assert_link 'Continue review'
      end
      match_group = find('[data-testid="unreviewed-match-group"]', text: members.first.full_name)
      within match_group do
        assert_text '3 records · 2 comparisons remaining'
        assert_selector '[data-testid="match-group-member"]', count: 3
        assert_button 'Compare next'
        assert_selector 'summary', text: 'Show pairings', count: 1
        assert_no_selector '[data-testid="match-group-review-disclosure"][open]', visible: :all
        assert_selector '[data-testid="unreviewed-pair-action"]', count: 2, visible: :all
        assert_no_selector "input[aria-label='Compare records: constituent records #{selected_ids.first} and #{selected_ids.second}']",
                           visible: :all
      end
      take_evidence_screenshot('duplicate-post-import-three-record-pair-in-progress', full: true, html: true)

      within('[data-testid="duplicate-review-case-row"]', text: members.first.full_name) do
        click_link 'Continue review'
      end
      assert_current_path admin_duplicate_review_path(review_case)
      assert_no_selector 'html[data-turbo-preview]', visible: :all

      within 'form[action$="/resolve"]' do
        fill_in 'rationale', with: 'Confirmed this exact pair represents different people.'
        click_button 'Resolve case'
      end

      assert_current_path admin_duplicate_reviews_path
      match_group = find('[data-testid="unreviewed-match-group"]', text: members.first.full_name)
      within match_group do
        assert_text '3 records · 2 comparisons remaining'
        assert_selector '[data-testid="match-group-member"]', count: 3
        assert_button 'Compare next'
        assert_selector 'summary', text: 'Show pairings', count: 1
        assert_no_selector '[data-testid="match-group-review-disclosure"][open]', visible: :all
        assert_selector '[data-testid="unreviewed-pair-action"]', count: 2, visible: :all
        assert_no_selector "input[aria-label='Compare records: constituent records #{selected_ids.first} and #{selected_ids.second}']",
                           visible: :all
      end
      take_evidence_screenshot('duplicate-post-import-three-record-one-pair-resolved', full: true, html: true)
    end

    private

    def create_unreviewed_pair
      create_unreviewed_group(count: 2)
    end

    def create_unreviewed_group(count:)
      attributes = {
        first_name: 'Imported',
        last_name: "QueueGroup#{SecureRandom.hex(3)}",
        date_of_birth: Date.new(1984, 9, 8),
        phone: nil,
        phone_type: nil,
        needs_duplicate_review: false
      }
      Array.new(count) do |index|
        create(:constituent, **attributes, email: "imported-queue-#{index}-#{SecureRandom.hex(5)}@example.com")
      end
    end
  end
end
