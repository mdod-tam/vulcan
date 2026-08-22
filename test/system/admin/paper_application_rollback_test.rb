# frozen_string_literal: true

require 'application_system_test_case'
require_relative 'paper_applications_test_helper'
require_relative '../../support/paper_application_context_helpers'
require Rails.root.join('test/support/system_test_evidence')

module Admin
  # What staff can actually do after a paper create fails and the whole transaction rolls back.
  #
  # "Usable retry form" is a claim about finishing the job without redoing it, so this test finishes
  # it that way: it asserts every submitted non-file value came back, reselects only the files the
  # restored dispositions actually require, changes nothing else, and checks the durable result
  # matches the decisions staff originally made.
  #
  # Two earlier versions proved less than they appeared to. One asserted two names and stopped, while
  # most of the form was being dropped. The next reattached through the shared accept-everything
  # helper, which silently overwrote the restored ID rejection -- proving staff could re-enter their
  # decisions, which is the opposite of the contract.
  #
  # The failure is forced at the proof-attachment boundary rather than by mangling the form, because
  # the subject is the response, not the cause.
  class PaperApplicationRollbackTest < ApplicationSystemTestCase
    include PaperApplicationsTestHelper
    include PaperApplicationContextHelpers
    include SystemTestEvidence

    PROOFS = {
      'medical_certification' => 'medical_certification_valid.pdf',
      'income_proof' => 'income_proof.pdf',
      'residency_proof' => 'residency_proof.pdf',
      'id_proof' => 'residency_proof.pdf'
    }.freeze

    setup do
      @admin = create(:admin)
      system_test_sign_in(@admin)
      setup_paper_application_context
      Current.paper_context = true
      setup_fpl_policies

      visit new_admin_paper_application_path
      assert_selector 'h1', text: 'Apply for Constituent'
      reveal_adult_application_sections
    end

    test 'a rolled-back create keeps every typed value and can be retried to success' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      fill_paper_form
      assert_no_difference ['User.count', 'Application.count'] do
        click_button 'Submit Paper Application'
        assert_text(/rejected by storage/i, wait: 15)
      end

      # Defensive: a failure must not navigate to an application the rollback removed. That path was
      # unreachable in practice -- see the service invariants -- but it is asserted so it stays so.
      assert_no_text(/not found/i)
      assert_no_match(%r{/admin/applications}, page.current_path)
      # The internal step name must not trail the real reason.
      assert_no_text(/Proof upload failed/i)

      assert_typed_values_survived
      assert_file_inputs_empty

      take_evidence_screenshot('paper-application-rollback-retry', full: true, html: true)

      # Finish the job by touching *only* the file inputs. Deliberately not the shared
      # attach-and-accept helper: that re-chooses "Accept & Upload" for every proof, which would
      # overwrite the restored ID rejection and make this test prove staff can re-enter their
      # decisions rather than that they never had to.
      ProofAttachmentService.unstub(:attach_proof)
      reattach_files_required_by_restored_dispositions
      sync_paper_submit_gate

      # The dispositions must still be exactly what was restored, immediately before submitting.
      assert_restored_dispositions

      assert_difference ['User.count', 'Application.count'], 1 do
        click_button 'Submit Paper Application'
        assert_selector 'h1', text: 'Application #', wait: 20
      end

      assert_durable_outcome_matches_restored_dispositions
      take_evidence_screenshot('paper-application-rollback-retry-succeeded', full: true, html: true)
    end

    private

    def fill_paper_form
      fill_in_applicant_information(first_name: 'Rollback', last_name: 'Retry')
      fill_in_application_details(household_size: 2, annual_income: 20_000)
      fill_in_disability_information
      fill_in_medical_provider_information
      attach_and_accept_proofs
      choose_non_default_proof_dispositions
      complete_paper_application_attestations
    end

    # Deliberately away from the defaults. Medical especially: "approved" is what a fresh form
    # selects, so leaving it there would let a total failure to restore look like success. The ID
    # proof is rejected with a reason, which is the state that was silently dropped entirely.
    def choose_non_default_proof_dispositions
      choose 'upload_only_medical_certification', allow_label_click: true
      choose 'reject_id_proof', allow_label_click: true
      select 'None Provided', from: 'id_proof_rejection_reason'
      sync_paper_submit_gate
    end

    # Everything the server is capable of restoring. Selected on the *enabled* input at page scope:
    # the dependent fieldset carries inputs under the same names and is disabled rather than removed,
    # so scoping by fieldset reads its empty fields and reports losses that never happened.
    def assert_typed_values_survived
      {
        'constituent[first_name]' => 'Rollback',
        'constituent[last_name]' => 'Retry',
        'application[household_size]' => '2',
        'application[medical_provider_name]' => 'Dr. Smith'
      }.each do |name, expected|
        assert_equal expected, enabled_field(name).value, "#{name} was not restored"
      end

      # Compared as a number: the field is currency-formatted, so its exact string is a display
      # concern and asserting it would break on formatting rather than on data loss.
      assert_equal 20_000,
                   enabled_field('application[annual_income]').value.to_s.gsub(/[^\d.]/, '').to_f.to_i,
                   'annual income was not restored'

      %w[application[maryland_resident] applicant_attributes[self_certify_disability]
         application[medical_release_authorized] application[terms_accepted]
         applicant_attributes[hearing_disability]].each do |name|
        assert enabled_checkbox(name).checked?, "#{name} was not restored"
      end

      # Workflow instructions, not attributes of any record, so nothing carries them back on its
      # own. All four groups, including the two moved off their defaults.
      { 'income_proof_action' => 'accept', 'residency_proof_action' => 'accept',
        'id_proof_action' => 'reject', 'medical_certification_action' => 'upload_only' }.each do |group, expected|
        assert_equal expected, checked_value(group), "#{group} was not restored"
      end

      assert_equal 'none_provided',
                   first('select[name="id_proof_rejection_reason"]', visible: :all).value,
                   'the rejection reason was not restored'
    end

    # Files only, and only where the restored disposition needs one. ID is restored as a rejection
    # for "None Provided", so attaching an ID document would contradict the decision being retried.
    def reattach_files_required_by_restored_dispositions
      { 'medical_certification' => 'medical_certification_valid.pdf',
        'income_proof' => 'income_proof.pdf',
        'residency_proof' => 'residency_proof.pdf' }.each do |field, fixture|
        attach_file field, Rails.root.join("test/fixtures/files/#{fixture}")
      end
    end

    def assert_restored_dispositions
      { 'income_proof_action' => 'accept', 'residency_proof_action' => 'accept',
        'id_proof_action' => 'reject', 'medical_certification_action' => 'upload_only' }.each do |group, expected|
        assert_equal expected, checked_value(group), "#{group} changed before the retry was submitted"
      end
      assert_equal 'none_provided',
                   first('select[name="id_proof_rejection_reason"]', visible: :all).value,
                   'the rejection reason changed before the retry was submitted'
    end

    # The point of the whole exercise: the decisions staff made the first time are the decisions the
    # database ends up with, without their having re-entered any of them.
    def assert_durable_outcome_matches_restored_dispositions
      application = Application.order(:id).last
      assert_equal 'Rollback', application.user.first_name
      assert_equal 2, application.household_size

      assert application.income_proof.attached?, 'income proof should have been attached'
      assert application.residency_proof.attached?, 'residency proof should have been attached'
      assert_equal 'approved', application.income_proof_status
      assert_equal 'approved', application.residency_proof_status

      assert application.medical_certification.attached?, 'the certification should have been attached'

      # The restored rejection has to survive all the way to durable state, document and all.
      assert_not application.id_proof.attached?, 'a rejected ID proof must not carry a document'
      assert_equal 'rejected', application.id_proof_status

      review = application.proof_reviews.find_by(proof_type: :id)
      assert_not_nil review, 'the ID rejection should have been recorded as a proof review'
      assert_equal 'rejected', review.status
      # The exact reason staff picked, not merely that some reason was stored: a restore that
      # substituted a different reason would still be present, and would still be wrong.
      # Both halves of the stored reason, exactly. A restore that substituted a different reason
      # would still be present and still be wrong, so presence alone proves nothing. The code is the
      # selection staff made; the text is what anyone reading the application later will see.
      assert_equal 'none_provided', review.rejection_reason_code,
                   'the durable rejection code must be the one that was restored on the form'
      assert_equal 'No ID proof was provided with the application.', review.rejection_reason,
                   'the durable rejection text must match the restored selection'
    end

    def checked_value(group)
      page.evaluate_script("document.querySelector('input[name=\"#{group}\"]:checked')?.value || ''")
    end

    # Stated rather than papered over: a server render cannot repopulate a native file input, so the
    # documents genuinely must be reselected. The test pins that this is the *only* thing lost.
    def assert_file_inputs_empty
      PROOFS.each_key do |field|
        selected = page.evaluate_script(
          "(document.querySelector('[name=\"#{field}\"]')?.files?.[0] || {}).name || ''"
        )
        assert_equal '', selected, "#{field} unexpectedly still holds a file"
      end
    end

    def enabled_field(name)
      first("[name=\"#{name}\"]:not([disabled])", visible: :all)
    end

    # Rails renders a hidden "0" companion immediately before each check box, under the same name.
    # Matching on name alone finds that hidden input, which is never checked -- so the assertion
    # fails while the real control is restored perfectly.
    def enabled_checkbox(name)
      first("input[type='checkbox'][name=\"#{name}\"]:not([disabled])", visible: :all)
    end
  end
end
