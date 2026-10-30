# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  # The proof cards appear for the constituent's own application and for each managed application, and both read
  # through the same partial.
  class DashboardProofCardsTest < ActionDispatch::IntegrationTest
    include AuthenticationTestHelper

    setup do
      @user = create(:constituent, :with_disabilities)
      sign_in_for_integration_test(@user)
    end

    test 'a rejected proof shows its reason, date and replacement link; other proofs show their own state' do
      application = create(:application, :in_progress, user: @user)
      application.update_columns(income_proof_required: true, income_proof_status: Application.income_proof_statuses[:rejected],
                                 residency_proof_status: Application.residency_proof_statuses[:approved],
                                 id_proof_status: Application.id_proof_statuses[:not_reviewed])
      review = create(:proof_review, :rejected, application: application, proof_type: 'income', notes: 'Scan was blurry')

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'h4', text: 'Income Proof'
      assert_select '.badge-danger', text: /Rejected/
      assert_select 'span', text: /Reason: Scan was blurry/
      assert_select 'div', text: /Rejected on: #{Regexp.escape(review.created_at.strftime('%B %d, %Y'))}/
      assert_select 'a[href=?]', constituent_portal_application_new_proof_path(application, proof_type: 'income'), text: 'Upload New Income Proof'
      assert_select 'h4', text: 'Residency Proof'
      assert_select '.badge-success', text: /Approved/
      assert_select 'h4', text: 'ID Proof'
      assert_select '.badge-info', text: /Pending Review/
    end

    test 'income proof is omitted when the application does not require it' do
      application = create(:application, :in_progress, user: @user)
      application.update_columns(income_proof_required: false)

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'h4', text: 'Income Proof', count: 0
      assert_select 'h4', text: 'Residency Proof'
      assert_select 'h4', text: 'ID Proof'
    end

    test 'a managed application gets the same cards' do
      dependent = create(:constituent, :with_disabilities)
      create(:guardian_relationship, guardian_user: @user, dependent_user: dependent)
      managed = create(:application, :in_progress, user: dependent, managing_guardian: @user)
      managed.update_columns(income_proof_required: false, residency_proof_status: Application.residency_proof_statuses[:rejected])
      create(:proof_review, :rejected, application: managed, proof_type: 'residency', notes: 'Wrong state')

      get constituent_portal_dashboard_path

      assert_response :success
      assert_select 'h3', text: /Document Status - #{Regexp.escape(dependent.full_name)}/
      assert_select 'span', text: /Reason: Wrong state/
      assert_select 'a[href=?]', constituent_portal_application_new_proof_path(managed, proof_type: 'residency'), text: 'Upload New Residency Proof'
    end
  end
end
