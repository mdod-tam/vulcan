# frozen_string_literal: true

require 'test_helper'

module ConstituentPortal
  class ApplicationsControllerTest < ActionDispatch::IntegrationTest
    include AutosaveTestHelper
    include ActionDispatch::TestProcess::FixtureFile
    include AuthenticationTestHelper

    setup do
      unique_email = "constituent_#{Time.now.to_i}_#{rand(1000)}@example.com"

      @user = create(:constituent, :with_disabilities, email: unique_email)
      # Archived status does not block a new submission.
      @application = create(:application, :archived, user: @user)
      @valid_pdf = fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
      @valid_image = fixture_file_upload(Rails.root.join('test/fixtures/files/residency_proof.pdf'), 'application/pdf')

      sign_in_for_integration_test(@user)

      ENV['DEBUG_AUTH'] = 'true'

      # The helper bypasses proof and waiting-period validation for these requests.
      setup_paper_application_context
    end

    teardown do
      teardown_paper_application_context
    end

    test 'request review route is not available' do
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(
          "/constituent_portal/applications/#{@application.id}/request_review",
          method: :post
        )
      end
    end

    test 'should handle array values for self_certify_disability' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "checkbox_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      post constituent_portal_applications_path, params: {
        application: {
          maryland_resident: true,
          household_size: 3,
          annual_income: 50_000,
          self_certify_disability: checkbox_params(true),
          hearing_disability: true
        },
        medical_provider: {
          name: 'Dr. Smith',
          phone: '2025551234',
          email: 'drsmith@example.com'
        },
        save_draft: 'Save Application'
      }

      assert_response :redirect

      application = Application.last

      assert_equal true, application.self_certify_disability
    end

    test 'should get new' do
      get new_constituent_portal_application_path

      assert_response :success
      assert_select 'h1', /New Application for/
      assert_select 'select[name="constituent[locale]"]'
      assert_select 'select[name="constituent[locale]"] option[value="en"]', text: 'English'
      assert_select 'select[name="constituent[locale]"] option[value="es"]', text: 'Spanish'
    end

    test 'should create application as draft' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "draft_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: true
          },
          medical_provider: {
            name: 'Dr. Smith',
            phone: '2025551234',
            email: 'drsmith@example.com'
          },
          save_draft: 'Save Application'
        }
      end

      application = Application.last

      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'draft', application.status
      assert_equal 'Dr. Smith', application.medical_provider_name
      assert_equal '2025551234', application.medical_provider_phone
      assert_equal 'drsmith@example.com', application.medical_provider_email
    end

    test 'should persist selected locale from new application form' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "locale_test_#{Time.now.to_i}_#{rand(1000)}@example.com",
                           locale: 'en')
      sign_in_for_integration_test(unique_user)

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 2,
            annual_income: 35_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true)
          },
          medical_provider: {
            name: 'Dr. Locale',
            phone: '2025556789',
            email: 'dr.locale@example.com'
          },
          constituent: {
            locale: 'es'
          },
          save_draft: 'Save Application'
        }
      end

      unique_user.reload
      assert_equal 'es', unique_user.locale
    end

    test 'should preserve existing locale when no locale is submitted' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "locale_preserve_test_#{Time.now.to_i}_#{rand(1000)}@example.com",
                           locale: 'es')
      sign_in_for_integration_test(unique_user)

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 2,
            annual_income: 35_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true)
          },
          medical_provider: {
            name: 'Dr. Preserve Locale',
            phone: '2025556790',
            email: 'dr.preserve.locale@example.com'
          },
          save_draft: 'Save Application'
        }
      end

      unique_user.reload
      assert_equal 'es', unique_user.locale
    end

    test 'should create application as submitted' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "submitted_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            terms_accepted: checkbox_params(true),
            information_verified: checkbox_params(true),
            medical_release_authorized: checkbox_params(true),
            medical_provider_attributes: {
              name: 'Dr. Smith',
              phone: '2025551234',
              email: 'drsmith@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      application = Application.last

      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'in_progress', application.status

      assert application.income_proof.attached?
      assert application.residency_proof.attached?
      assert_equal 'not_reviewed', application.income_proof_status
      assert_equal 'not_reviewed', application.residency_proof_status
    end

    # A pending registration soft-match case produces an informational refusal, with no new application.
    # The response preserves entered values and explains how to restore file selections.
    test 'blocked submission re-renders the form with the pending-review explanation and no application' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "pending_review_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      open_soft_match_case_for(unique_user)

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path, params: pending_review_submission_params
      end

      assert_response :unprocessable_content
      assert_select '#pending-review-notice[role=?]', 'status'
      assert_select '#pending-review-notice',
                    text: /#{Regexp.escape(pending_review_message)}/
      assert_select '#error-summary', false,
                    'a pending review is not a validation error and must not render the error summary'
      assert_select "input[name='application[household_size]'][value='3']"
      # A server response cannot restore selected files.
      assert_select '#pending-review-documents-notice',
                    text: /#{Regexp.escape(refused_documents_message)}/
    end

    # Autosave leaves the new form on the create route. The full save must resume its draft.
    test 'Save Application posted to create continues the draft autosave already started' do
      applicant = create(:constituent, :with_disabilities)
      sign_in_for_integration_test(applicant)
      draft = autosaved_draft(applicant, household_size: '2')

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path,
             params: pending_review_submission_params.except(:submit_application).merge(save_draft: 'Save Application')
      end

      assert_redirected_to constituent_portal_application_path(draft)
      draft.reload
      assert_equal 'draft', draft.status
      assert_equal 3, draft.household_size, 'the full form is authoritative over the autosaved value'
    end

    test 'Submit posted to create submits the dependent draft autosave already started' do
      guardian = create(:constituent, :with_disabilities)
      dependent = create(:constituent, :with_disabilities)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
      sign_in_for_integration_test(guardian)
      draft = autosaved_draft(guardian, household_size: '2', user_id: dependent.id)

      params = pending_review_submission_params
      params[:application] = params[:application].merge(user_id: dependent.id, for_self: 'false')
      assert_no_difference('Application.count') do
        post constituent_portal_applications_path, params: params
      end

      assert_redirected_to constituent_portal_application_path(draft)
      draft.reload
      assert_equal 'in_progress', draft.status
      assert_equal [dependent.id, guardian.id], [draft.user_id, draft.managing_guardian_id]
      assert_equal 0, Application.where(user: guardian).count, 'nothing may be filed as the guardian'
    end

    # The refusal shows submitted values and changes the form action to update the resumed draft.
    test 'a refused create that resumed a draft keeps typed values and an unchanged retry submits that draft' do
      applicant = create(:constituent, :with_disabilities)
      sign_in_for_integration_test(applicant)
      draft = autosaved_draft(applicant, household_size: '7')
      review_case = open_soft_match_case_for(applicant)

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path, params: pending_review_submission_params
      end

      assert_response :unprocessable_content
      assert_select '#pending-review-notice'
      assert_select "input[name='application[household_size]'][value='3']"
      assert_select "form[action='#{constituent_portal_application_path(draft)}'] input[name='_method'][value='patch']"
      assert_equal 7, draft.reload.household_size, 'a refusal saves nothing'

      review_case.update!(status: :resolved_ignored, resolution_determination: :keep_separate,
                          resolution_rationale: 'Different people', resolved_by: create(:admin),
                          resolved_at: Time.current)
      patch constituent_portal_application_path(draft), params: pending_review_submission_params

      assert_redirected_to constituent_portal_application_path(draft)
      assert_equal ['in_progress', 3], draft.reload.values_at(:status, :household_size)
    end

    # The GET notice precedes file selection, so it must not claim files were lost.
    test 'the arrival notice does not mention lost documents' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "arrival_docs_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      open_soft_match_case_for(unique_user)

      get new_constituent_portal_application_path

      assert_response :success
      assert_select '#pending-review-notice'
      assert_select '#pending-review-documents-notice', false,
                    'nothing has been selected on arrival, so nothing can have been lost'
    end

    test 'resolving the review unblocks the form and lets the submission through' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "resolved_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      review_case = open_soft_match_case_for(unique_user)

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path, params: pending_review_submission_params
      end
      assert_select '#pending-review-notice'

      review_case.update!(
        status: :resolved_ignored,
        resolution_determination: :keep_separate,
        resolution_rationale: 'confirmed different people',
        resolved_by: create(:admin),
        resolved_at: Time.current
      )

      get new_constituent_portal_application_path
      assert_response :success
      assert_select '#pending-review-notice', false, 'a resolved case must stop warning'
      assert_select 'form[data-final-submit-gate-blocked-message]', false,
                    'a resolved case must stop blocking the submit control'

      assert_difference('Application.count', 1) do
        post constituent_portal_applications_path, params: pending_review_submission_params
      end
      assert_equal 'in_progress', Application.last.status,
                   'the previously refused submission must now be accepted'
    end

    # Raw locale parameters can contain unsupported values. ApplicationForm must select a supported locale
    # so I18n does not replace the informational refusal with a generic error response.
    test 'a tampered locale still renders the pending-review notice rather than a validation error' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "pending_locale_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      open_soft_match_case_for(unique_user)

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path,
             params: pending_review_submission_params.merge(constituent: { locale: 'xx' })
      end

      assert_response :unprocessable_content
      assert_select '#pending-review-notice', text: /#{Regexp.escape(pending_review_message)}/
      assert_select '#error-summary', false,
                    'a forged locale must not degrade the refusal into the red error summary'
    end

    # The GET warning avoids file selection for a blocked submission. File selections cannot survive a refusal.
    test 'the new form warns and blocks submission before any upload while identity review is pending' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "pending_new_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      open_soft_match_case_for(unique_user)

      get new_constituent_portal_application_path

      assert_response :success
      assert_select '#pending-review-notice', text: /#{Regexp.escape(pending_review_message)}/
      assert_select 'form[data-final-submit-gate-blocked-message=?]', submission_gate_blocked_message
      assert_select "input[name='save_draft']"
      assert_select "input[name='save_draft'][disabled]", false,
                    'draft saving must stay reachable: only final submission is gated'
    end

    test 'the new form carries no block when no identity review is pending' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "no_pending_new_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      get new_constituent_portal_application_path

      assert_response :success
      assert_select '#pending-review-notice', false
      assert_select 'form[data-final-submit-gate-blocked-message]', false
    end

    test 'the edit form warns and blocks submission while identity review is pending' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "pending_edit_get_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      draft = create(:application, :draft, user: unique_user)
      open_soft_match_case_for(unique_user)

      get edit_constituent_portal_application_path(draft)

      assert_response :success
      assert_select '#pending-review-notice'
      assert_select 'form[data-final-submit-gate-blocked-message=?]', submission_gate_blocked_message
    end

    # The review block follows the applicant, not the acting guardian.
    test 'a guardian editing a gated dependent application sees the block' do
      guardian = create(:constituent, :with_disabilities,
                        email: "guardian_gate_#{Time.now.to_i}_#{rand(1000)}@example.com")
      dependent = create(:constituent, :with_disabilities,
                         email: "dependent_gate_#{Time.now.to_i}_#{rand(1000)}@example.com")
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent,
                                   relationship_type: 'parent')
      sign_in_for_integration_test(guardian)
      draft = create(:application, :draft, user: dependent, managing_guardian: guardian)
      open_soft_match_case_for(dependent)

      get edit_constituent_portal_application_path(draft)

      assert_response :success
      assert_select 'form[data-final-submit-gate-blocked-message=?]', submission_gate_blocked_message
    end

    test 'a guardian own open case does not block a dependent application' do
      guardian = create(:constituent, :with_disabilities,
                        email: "guardian_ungated_#{Time.now.to_i}_#{rand(1000)}@example.com")
      dependent = create(:constituent, :with_disabilities,
                         email: "dependent_ungated_#{Time.now.to_i}_#{rand(1000)}@example.com")
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent,
                                   relationship_type: 'parent')
      sign_in_for_integration_test(guardian)
      draft = create(:application, :draft, user: dependent, managing_guardian: guardian)
      open_soft_match_case_for(guardian)

      get edit_constituent_portal_application_path(draft)

      assert_response :success
      assert_select '#pending-review-notice', false
      assert_select 'form[data-final-submit-gate-blocked-message]', false
    end

    # A refusal must preserve the dependent applicant and hidden id so a retry cannot change the owner.
    test 'a refused dependent submission keeps the application scoped to the dependent' do
      guardian, dependent = guardian_and_dependent
      sign_in_for_integration_test(guardian)
      open_soft_match_case_for(dependent)

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path,
             params: pending_review_submission_params.deep_merge(
               application: { user_id: dependent.id, use_guardian_address: '1' }
             )
      end

      assert_response :unprocessable_content
      assert_select '#error-summary', false,
                    'a form-only attribute must not reach Application and surface as a raw error'
      assert_select "input[name='application[user_id]'][value='#{dependent.id}']", 1,
                    'the refusal must keep the hidden dependent id, or a retry saves to the guardian'
      assert_select 'p', text: /This application is for\s+#{Regexp.escape(dependent.full_name)}/,
                         count: 1
      assert_no_match(/unknown attribute/i, response.body)
    end

    # Resolve the posted id through the guardian association before the form displays a dependent.
    test 'a forged dependent id in a refused submission falls back to a self application' do
      guardian, = guardian_and_dependent
      stranger = create(:constituent, :with_disabilities,
                        email: "stranger_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(guardian)
      open_soft_match_case_for(guardian)

      post constituent_portal_applications_path,
           params: pending_review_submission_params.deep_merge(
             application: { user_id: stranger.id }
           )

      assert_response :unprocessable_content
      assert_select "input[name='application[user_id]'][value='#{stranger.id}']", false,
                    'an unverified dependent id must not be echoed back into the form'
      assert_no_match(/#{Regexp.escape(stranger.full_name)}/, response.body)
    end

    # ParamCasting converts checkbox arrays to booleans. The view must not compare them with "1".
    test 'a refused submission keeps the submitted disability selections in both directions' do
      unique_user = create(:constituent, email: "disability_#{Time.now.to_i}_#{rand(1000)}@example.com",
                                         hearing_disability: true, vision_disability: false)
      sign_in_for_integration_test(unique_user)
      open_soft_match_case_for(unique_user)

      post constituent_portal_applications_path,
           params: pending_review_submission_params.deep_merge(
             application: { hearing_disability: checkbox_params(false),
                            vision_disability: checkbox_params(true) }
           )

      assert_response :unprocessable_content
      assert_select "input[name='application[hearing_disability]'][checked]", false,
                    'unchecking a stored disability must survive the refusal'
      assert_select "input[name='application[vision_disability]'][checked]", 1,
                    'a newly checked disability must survive the refusal'
    end

    # Submitted guardian-address choice must override stored address blankness after a refusal.
    test 'a refused dependent submission keeps the submitted guardian-address choice' do
      guardian, dependent = guardian_and_dependent
      sign_in_for_integration_test(guardian)
      draft = create(:application, :draft, user: dependent, managing_guardian: guardian)
      open_soft_match_case_for(dependent)

      patch constituent_portal_application_path(draft),
            params: pending_review_submission_params.deep_merge(
              application: { use_guardian_address: '0', physical_address_1: '9 Dependent Ln',
                             city: 'Rockville', state: 'MD', zip_code: '20850' }
            )

      assert_response :unprocessable_content
      assert_select 'input#use_guardian_address_checkbox[checked]', false,
                    'an unchecked guardian-address box must not come back checked'
      assert_select "input[name='application[physical_address_1]'][value='9 Dependent Ln']", 1
    end

    # An update derives the applicant from the persisted draft because the edit form omits application[user_id].
    # A dependent with their own contact uses their own locale. Guardian-contact dependents use the guardian locale.
    test 'a refused update on a Spanish dependent draft renders in the dependent locale' do
      guardian, dependent = guardian_and_dependent
      guardian.update!(locale: 'en')
      dependent.update!(locale: 'es', dependent_email: "own_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(guardian)
      draft = create(:application, :draft, user: dependent, managing_guardian: guardian)
      open_soft_match_case_for(dependent)

      patch constituent_portal_application_path(draft), params: pending_review_submission_params

      assert_response :unprocessable_content
      spanish = I18n.t('activemodel.errors.models.application_form.attributes.base.pending_identity_review',
                       locale: :es)
      assert_select '#pending-review-notice', text: /#{Regexp.escape(spanish)}/
      assert_no_match(/#{Regexp.escape(pending_review_message)}/, response.body,
                      'the English copy must not appear alongside the Spanish refusal')
      assert_equal 'draft', draft.reload.status
    end

    # The refusal preserves the stored draft but renders the latest submitted values.
    test 'blocked submission on an existing draft leaves the draft intact and keeps the edits shown' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "pending_edit_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      draft = create(:application, :draft, user: unique_user, household_size: 2)
      open_soft_match_case_for(unique_user)

      assert_no_difference('Application.count') do
        patch constituent_portal_application_path(draft),
              params: pending_review_submission_params.deep_merge(
                application: { household_size: 7 }
              )
      end

      assert_response :unprocessable_content
      assert_select '#pending-review-notice'

      draft.reload
      assert_equal 'draft', draft.status, 'the refused submission must not advance the draft'
      assert_equal 2, draft.household_size, 'the stored draft must be untouched by the refusal'
      assert_select "input[name='application[household_size]'][value='7']"
    end

    # Without submit_application, this request saves a draft despite the pending review.
    test 'a draft save is not blocked while a registration soft match case is open' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "pending_draft_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      open_soft_match_case_for(unique_user)

      assert_difference('Application.count', 1) do
        post constituent_portal_applications_path,
             params: pending_review_submission_params.except(:submit_application)
      end

      assert_equal 'draft', Application.last.status
    end

    test 'should not submit application without provider info when no provider flag is posted' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "missing_provider_submit_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)
      Applications::RequestProviderInfo.expects(:new).never

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            no_provider_info_provided: '1',
            medical_provider_attributes: {
              name: '',
              phone: '',
              email: ''
            }
          },
          submit_application: 'Submit Application'
        }
      end

      assert_response :unprocessable_content
      expected = I18n.t(
        'activemodel.errors.models.application_form.attributes.base.medical_provider_required',
        locale: 'en'
      )
      assert_equal expected, flash[:alert]
      assert_match expected, response.body
    end

    test 'should not submit application without provider info when preferred language is Spanish' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "missing_provider_submit_es_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      assert_no_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          constituent: { locale: 'es' },
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            no_provider_info_provided: '1',
            medical_provider_attributes: {
              name: '',
              phone: '',
              email: ''
            }
          },
          submit_application: 'Submit Application'
        }
      end

      assert_response :unprocessable_content
      expected = I18n.t(
        'activemodel.errors.models.application_form.attributes.base.medical_provider_required',
        locale: 'es'
      )
      assert_equal expected, flash[:alert]
      assert_match expected, response.body
    end

    test 'guardian should create application for a dependent' do
      guardian = create(:constituent, email: 'guardian.app.creator@example.com', phone: '5555550020')
      dependent = create(:constituent, email: 'dependent.app.subject@example.com', phone: '5555550021')
      GuardianRelationship.create!(guardian_id: guardian.id, dependent_id: dependent.id, relationship_type: 'parent')

      sign_in_for_integration_test guardian

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            user_id: dependent.id,
            maryland_resident: true,
            household_size: 2,
            annual_income: 30_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            terms_accepted: checkbox_params(true),
            information_verified: checkbox_params(true),
            medical_release_authorized: checkbox_params(true),
            medical_provider_attributes: {
              name: 'Dr. Child',
              phone: '2025551212',
              email: 'drchild@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)

      assert_equal(dependent.id, application.user_id, 'Application user_id should be the dependent')
      assert_equal(guardian.id, application.managing_guardian_id, 'Application managing_guardian_id should be the guardian')
      assert_equal('in_progress', application.status)

      assert application.income_proof.attached?
      assert application.residency_proof.attached?
    end

    test 'guardian should persist locale to dependent applicant only' do
      guardian = create(:constituent,
                        email: "guardian.locale.portal.#{Time.now.to_i}@example.com",
                        phone: '5555551050',
                        locale: 'en')
      dependent = create(:constituent,
                         email: "dependent.locale.portal.#{Time.now.to_i}@example.com",
                         phone: '5555551051',
                         locale: 'en')
      GuardianRelationship.create!(guardian_id: guardian.id, dependent_id: dependent.id, relationship_type: 'parent')

      sign_in_for_integration_test guardian

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            user_id: dependent.id,
            maryland_resident: true,
            household_size: 2,
            annual_income: 32_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            terms_accepted: checkbox_params(true),
            information_verified: checkbox_params(true),
            medical_release_authorized: checkbox_params(true)
          },
          medical_provider: {
            name: 'Dr. Portal Locale',
            phone: '2025553050',
            email: 'dr.portal.locale@example.com'
          },
          constituent: {
            locale: 'es'
          },
          save_draft: 'Save Application'
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal dependent.id, application.user_id
      assert_equal guardian.id, application.managing_guardian_id

      guardian.reload
      dependent.reload
      assert_equal 'en', guardian.locale
      assert_equal 'es', dependent.locale
    end

    test 'should show application' do
      get constituent_portal_application_path(@application)

      assert_response :success
      assert_select 'h1', /Application ##{@application.id}/
    end

    test 'should get edit for draft application' do
      @application.update!(status: :draft)

      get edit_constituent_portal_application_path(@application)

      assert_response :success
    end

    test 'should not get edit for submitted application' do
      @application.income_proof.attach(@valid_pdf)
      @application.residency_proof.attach(@valid_image)

      @application.update!(status: :in_progress)

      get edit_constituent_portal_application_path(@application)

      assert_redirected_to constituent_portal_application_path(@application)
      assert_flash_message(:alert, 'This application has already been submitted and cannot be edited.')
    end

    test 'should update draft application' do
      @application.update!(status: :draft)

      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 4,
          annual_income: 60_000,
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false)
        }
      }

      assert_redirected_to constituent_portal_application_path(@application)

      @application.reload
      assert_equal 4, @application.household_size
      assert_equal 60_000, @application.annual_income

      # Disability attributes belong to the applicant user, not the application.
      @user.reload
      assert_equal true, @user.hearing_disability
    end

    test 'should submit draft application' do
      @application.update!(
        status: :draft,
        household_size: 3,
        annual_income: 50_000,
        medical_provider_name: 'Dr. Smith',
        medical_provider_phone: '2025551234',
        medical_provider_email: 'drsmith@example.com'
      )

      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 4,
          annual_income: 60_000,
          maryland_resident: true,
          self_certify_disability: true,
          terms_accepted: true,
          information_verified: true,
          medical_release_authorized: true,
          hearing_disability: checkbox_params(true), # Submission requires at least one disability.
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false),
          residency_proof: @valid_image,
          income_proof: @valid_pdf,
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '2025551234',
            email: 'drsmith@example.com'
          }
        },
        submit_application: 'Submit Application'
      }

      assert_redirected_to constituent_portal_application_path(@application)

      @application.reload
      assert_equal 'in_progress', @application.status
    end

    test 'should not update submitted application' do
      @application.income_proof.attach(@valid_pdf)
      @application.residency_proof.attach(@valid_image)

      @application.update!(status: :in_progress, household_size: 3, annual_income: 50_000)

      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 4,
          annual_income: 60_000
        }
      }

      assert_redirected_to constituent_portal_application_path(@application)
      assert_flash_message(:alert, 'This application has already been submitted and cannot be edited.')

      @application.reload
      assert_equal 3, @application.household_size
      assert_equal 50_000, @application.annual_income.to_i
    end

    test 'should show validation errors for invalid submission' do
      post constituent_portal_applications_path, params: {
        application: {
          maryland_resident: false,
          household_size: '',
          annual_income: ''
        },
        submit_application: 'Submit Application'
      }

      assert_response :unprocessable_content

      assert_match(/maryland resident|residency/i, response.body)
      assert_match(/household size|size.*blank/i, response.body)
      assert_match(/annual income|income.*blank/i, response.body)
    end

    test 'should show uploaded document filenames on show page' do
      @application.income_proof.attach(@valid_pdf)
      @application.residency_proof.attach(@valid_image)
      @application.save!

      get constituent_portal_application_path(@application)

      assert_response :success
      assert_select 'span', /Filename:/
    end

    test 'helper methods should return correct FPL thresholds' do
      setup_fpl_policies

      get new_constituent_portal_application_path
      assert_response :success

      thresholds_json = @controller.fpl_thresholds_json
      modifier = @controller.fpl_modifier_value

      thresholds = JSON.parse(thresholds_json)
      assert_equal 15_650, thresholds['1']
      assert_equal 21_150, thresholds['2']
      assert_equal 26_650, thresholds['3']
      assert_equal 32_150, thresholds['4']
      assert_equal 37_650, thresholds['5']
      assert_equal 43_150, thresholds['6']
      assert_equal 48_650, thresholds['7']
      assert_equal 54_150, thresholds['8']

      assert_equal 400, modifier
    end

    test 'should maintain user association during update' do
      @application.update!(status: :draft,
                           household_size: 3,
                           annual_income: 50_000,
                           medical_provider_name: 'Good Health Clinic')

      patch constituent_portal_application_path(@application), params: {
        application: {
          household_size: 5,
          annual_income: 75_000,
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(true),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false),
          medical_provider_attributes: {
            name: 'Dr. Jane Smith',
            phone: '2025559876',
            email: 'drjane@example.com'
          }
        }
        # Without submit_application, this request updates the draft.
      }

      assert_redirected_to constituent_portal_application_path(@application)

      @application.reload

      assert_equal 5, @application.household_size
      assert_equal 75_000, @application.annual_income

      assert_equal 'Dr. Jane Smith', @application.medical_provider_name
      assert_equal '2025559876', @application.medical_provider_phone
      assert_equal 'drjane@example.com', @application.medical_provider_email

      assert_not_nil @application.user_id
      assert_equal @user.id, @application.user_id

      @user.reload
      assert_equal true, @user.hearing_disability
      assert_equal true, @user.vision_disability
      assert_equal false, @user.speech_disability
      assert_equal false, @user.mobility_disability
      assert_equal false, @user.cognition_disability
    end

    test 'should update application with managing guardian' do
      dependent = create(:constituent, :with_disabilities,
                         email: 'dependent_for_update_test@example.com')

      GuardianRelationship.create!(
        guardian_id: @user.id,
        dependent_id: dependent.id,
        relationship_type: 'parent'
      )

      # The managing guardian can edit this dependent draft.
      dependent_app = create(:application,
                             user: dependent,
                             status: :draft,
                             managing_guardian_id: @user.id)

      assert_equal @user.id, dependent_app.managing_guardian_id,
                   'managing_guardian_id should be set during creation'

      patch constituent_portal_application_path(dependent_app), params: {
        application: {
          household_size: 2,
          annual_income: 30_000,
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false)
        }
        # Without submit_application, this request updates the draft.
      }

      assert_redirected_to constituent_portal_application_path(dependent_app)

      dependent_app.reload

      assert_equal @user.id, dependent_app.managing_guardian_id
      assert dependent_app.for_dependent?, 'Application should be marked as for a dependent'
      assert_equal 'parent', dependent_app.guardian_relationship_type
      assert_equal 2, dependent_app.household_size
      assert_equal 30_000, dependent_app.annual_income
    end

    test 'should save address information to user during application creation' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "address_creation_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      unique_user.update!(
        physical_address_1: nil,
        physical_address_2: nil,
        city: nil,
        state: nil,
        zip_code: nil
      )

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 3,
            annual_income: 50_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            physical_address_1: '134 main st',
            physical_address_2: 'Apt 2B',
            city: 'baltimore',
            state: 'MD',
            zip_code: '21201',
            terms_accepted: checkbox_params(true),
            information_verified: checkbox_params(true),
            medical_release_authorized: checkbox_params(true)
          },
          medical_provider_attributes: {
            name: 'Dr. Smith',
            phone: '2025551234',
            email: 'drsmith@example.com'
          },
          save_draft: 'Save Application'
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'draft', application.status

      # Address fields belong to the applicant user, not the application.
      unique_user.reload
      assert_equal '134 main st', unique_user.physical_address_1, 'Address line 1 should be saved to user'
      assert_equal 'Apt 2B', unique_user.physical_address_2, 'Address line 2 should be saved to user'
      assert_equal 'baltimore', unique_user.city, 'City should be saved to user'
      assert_equal 'MD', unique_user.state, 'State should be saved to user'
      assert_equal '21201', unique_user.zip_code, 'ZIP code should be saved to user'
    end

    test 'should save address information to user during application submission' do
      unique_user = create(:constituent, :with_disabilities,
                           email: "address_submission_test_#{Time.now.to_i}_#{rand(1000)}@example.com")
      sign_in_for_integration_test(unique_user)

      unique_user.update!(
        physical_address_1: nil,
        physical_address_2: nil,
        city: nil,
        state: nil,
        zip_code: nil
      )

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            maryland_resident: true,
            household_size: 4,
            annual_income: 45_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            physical_address_1: '456 Oak Street',
            physical_address_2: '',
            city: 'Silver Spring',
            state: 'MD',
            zip_code: '20901',
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            terms_accepted: checkbox_params(true),
            information_verified: checkbox_params(true),
            medical_release_authorized: checkbox_params(true),
            medical_provider_attributes: {
              name: 'Dr. Johnson',
              phone: '3015551234',
              email: 'drjohnson@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)
      assert_equal 'in_progress', application.status

      # Address fields belong to the applicant user, not the application.
      unique_user.reload
      assert_equal '456 Oak Street', unique_user.physical_address_1, 'Address line 1 should be saved to user'
      assert_equal '', unique_user.physical_address_2, 'Address line 2 should be saved to user (empty string)'
      assert_equal 'Silver Spring', unique_user.city, 'City should be saved to user'
      assert_equal 'MD', unique_user.state, 'State should be saved to user'
      assert_equal '20901', unique_user.zip_code, 'ZIP code should be saved to user'
    end

    test 'should save address information to dependent user when guardian creates application' do
      guardian = create(:constituent,
                        email: 'guardian.address.test@example.com',
                        phone: '5555550030',
                        physical_address_1: '999 Guardian Lane',
                        city: 'Bethesda',
                        state: 'MD',
                        zip_code: '20814')
      dependent = create(:constituent,
                         email: 'dependent.address.test@example.com',
                         phone: '5555550031',
                         physical_address_1: nil,
                         physical_address_2: nil,
                         city: nil,
                         state: nil,
                         zip_code: nil)
      GuardianRelationship.create!(guardian_id: guardian.id, dependent_id: dependent.id, relationship_type: 'parent')

      sign_in_for_integration_test guardian

      assert_difference('Application.count') do
        post constituent_portal_applications_path, params: {
          application: {
            user_id: dependent.id,
            maryland_resident: true,
            household_size: 2,
            annual_income: 30_000,
            self_certify_disability: checkbox_params(true),
            hearing_disability: checkbox_params(true),
            vision_disability: checkbox_params(false),
            speech_disability: checkbox_params(false),
            mobility_disability: checkbox_params(false),
            cognition_disability: checkbox_params(false),
            physical_address_1: '789 Elm Avenue',
            physical_address_2: 'Unit 5',
            city: 'Rockville',
            state: 'MD',
            zip_code: '20850',
            residency_proof: @valid_image,
            income_proof: @valid_pdf,
            terms_accepted: checkbox_params(true),
            information_verified: checkbox_params(true),
            medical_release_authorized: checkbox_params(true),
            medical_provider_attributes: {
              name: 'Dr. Child',
              phone: '2025551212',
              email: 'drchild@example.com'
            }
          },
          submit_application: 'Submit Application'
        }
      end

      application = Application.last
      assert_redirected_to constituent_portal_application_path(application)

      assert_equal(dependent.id, application.user_id, 'Application user_id should be the dependent')
      assert_equal(guardian.id, application.managing_guardian_id, 'Application managing_guardian_id should be the guardian')

      # The dependent owns the submitted address. The guardian address must remain unchanged.
      dependent.reload
      guardian.reload

      assert_equal '789 Elm Avenue', dependent.physical_address_1, 'Address line 1 should be saved to dependent user'
      assert_equal 'Unit 5', dependent.physical_address_2, 'Address line 2 should be saved to dependent user'
      assert_equal 'Rockville', dependent.city, 'City should be saved to dependent user'
      assert_equal 'MD', dependent.state, 'State should be saved to dependent user'
      assert_equal '20850', dependent.zip_code, 'ZIP code should be saved to dependent user'

      assert_equal '999 Guardian Lane', guardian.physical_address_1, 'Guardian address should not be affected'
      assert_equal 'Bethesda', guardian.city, 'Guardian city should not be affected'
    end

    private

    def pending_review_message
      I18n.t('activemodel.errors.models.application_form.attributes.base.pending_identity_review')
    end

    def submission_gate_blocked_message
      I18n.t('applications.submission_gate.pending_identity_review_status')
    end

    def refused_documents_message
      I18n.t('applications.submission_gate.refused_documents_notice')
    end

    def guardian_and_dependent
      stamp = "#{Time.now.to_i}_#{rand(10_000)}"
      guardian = create(:constituent, :with_disabilities, first_name: 'Gina', last_name: 'Guardian',
                                                          email: "guardian_#{stamp}@example.com")
      dependent = create(:constituent, :with_disabilities, first_name: 'Dana', last_name: 'Dependent',
                                                           email: "dependent_#{stamp}@example.com")
      GuardianRelationship.create!(guardian_user: guardian, dependent_user: dependent,
                                   relationship_type: 'parent')
      [guardian, dependent]
    end

    def autosaved_draft(actor, household_size:, user_id: nil)
      result = Applications::AutosaveService.new(
        current_user: actor,
        params: { **autosave_metadata(actor: actor, applicant: user_id ? User.find(user_id) : actor),
          user_id: user_id, field_name: 'application[household_size]', field_value: household_size }.compact
      ).call
      assert result[:success], "autosave setup failed: #{result[:errors]}"
      Application.find(result[:application_id])
    end

    def open_soft_match_case_for(subject)
      DuplicateReviewCase.create!(
        source: :registration_soft_match,
        subject_user: subject,
        deduplication_key: SecureRandom.hex(16),
        metadata: { 'reason_codes' => ['name_dob'] },
        opened_at: Time.current,
        status: :open
      )
    end

    def pending_review_submission_params
      {
        application: {
          maryland_resident: true,
          household_size: 3,
          annual_income: 50_000,
          self_certify_disability: checkbox_params(true),
          hearing_disability: checkbox_params(true),
          vision_disability: checkbox_params(false),
          speech_disability: checkbox_params(false),
          mobility_disability: checkbox_params(false),
          cognition_disability: checkbox_params(false),
          residency_proof: @valid_image,
          income_proof: @valid_pdf,
          terms_accepted: checkbox_params(true),
          information_verified: checkbox_params(true),
          medical_release_authorized: checkbox_params(true),
          medical_provider_attributes: {
            name: 'Dr. Smith', phone: '2025551234', email: 'drsmith@example.com'
          }
        },
        submit_application: 'Submit Application'
      }
    end
  end
end
