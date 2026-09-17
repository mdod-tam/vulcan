# frozen_string_literal: true

require 'test_helper'

module Admin
  class PaperIdentityIntakeTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin)
      sign_in_for_integration_test(@admin)
      setup_fpl_policies
      @candidate = create(:constituent, first_name: 'Robin', last_name: 'Paper', date_of_birth: Date.new(1980, 2, 3))
      @params = {
        applicant_type: 'self', no_email_address: '1', no_phone_number: '1',
        constituent: {
          first_name: 'Robin', last_name: 'Paper', date_of_birth: '1980-02-03',
          physical_address_1: '123 Main St', city: 'Baltimore', state: 'MD', zip_code: '21201',
          hearing_disability: '1', communication_preference: 'letter'
        },
        application: {
          household_size: 2, annual_income: 20_000, maryland_resident: true, self_certify_disability: true,
          medical_provider_name: 'Doctor Example', medical_provider_phone: '555-123-4567',
          medical_provider_email: 'doctor@example.org', terms_accepted: true,
          information_verified: true, medical_release_authorized: true
        }
      }
      @blobs = %w[income_proof residency_proof id_proof medical_certification].to_h do |key|
        blob = ActiveStorage::Blob.create_and_upload!(
          io: File.open(file_fixture('income_proof.pdf')), filename: "#{key}.pdf", content_type: 'application/pdf'
        )
        @params["#{key}_action"] = 'upload_only'
        @params["#{key}_signed_id"] = blob.signed_id
        [key, blob]
      end
    end

    test 'normal POST renders identity review with all four uploaded documents and commits resolved cases on confirmation' do
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'] do
        post admin_paper_applications_path, params: @params
      end
      assert_response :unprocessable_content
      assert_select '#identity-review-heading', text: 'Review possible matches'
      @blobs.each do |key, blob|
        assert_select "input[type=hidden][name='#{key}_signed_id'][value='#{blob.signed_id}']"
        assert_select 'p', text: "Uploaded: #{blob.filename}"
      end

      receipt = css_select('input[name=identity_review_receipt]').sole['value']
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'] do
        post admin_paper_applications_path, params: @params.merge(
          application: @params[:application].merge(alternate_contact_email: 'not-an-email'),
          identity_review_receipt: receipt, identity_determination: 'keep_separate',
          identity_rationale: 'Paper address and identity evidence confirm a different person.'
        )
      end
      assert_response :unprocessable_content
      assert_select 'input[type=hidden][name=identity_determination][value=keep_separate]'
      @blobs.each do |key, blob|
        assert_select "input[type=hidden][name='#{key}_signed_id'][value='#{blob.signed_id}']"
      end
      receipt = css_select('input[name=identity_review_receipt]').sole['value']
      assert_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'], 1 do
        post admin_paper_applications_path, params: @params.merge(
          identity_review_receipt: receipt, identity_determination: 'keep_separate',
          identity_rationale: 'Paper address and identity evidence confirm a different person.'
        )
      end
      assert_response :redirect
      application = Application.order(:id).last
      @blobs.each { |key, blob| assert_equal blob, application.public_send(key).blob }
      review_case = DuplicateReviewCase.order(:id).last
      assert review_case.resolved_ignored?
      assert_equal application.id, review_case.metadata['application_id']
    end

    test 'old pages reach canonical review without losing multipart documents or authorizing a legacy decision' do
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count', 'Event.count'] do
        post identity_review_admin_paper_applications_path, params: { constituent: @params[:constituent] }, as: :json
      end
      assert_response :success
      assert_equal({ 'state' => 'clear' }, response.parsed_body)
      assert_equal 'no-store', response.headers['Cache-Control']

      legacy = @params.merge(identity_decision: 'obsolete-decision')
      @blobs.each_key do |key|
        legacy.delete("#{key}_signed_id")
        legacy[key] = fixture_file_upload('income_proof.pdf', 'application/pdf')
      end
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count', 'Event.count'] do
        post admin_paper_applications_path, params: legacy
      end
      assert_response :unprocessable_content
      assert_select '#identity-review-heading'
      retained = @blobs.keys.to_h do |key|
        signed_id = css_select("input[type=hidden][name='#{key}_signed_id']").sole['value']
        blob = ActiveStorage::Blob.find_signed!(signed_id)
        assert_equal file_fixture('income_proof.pdf').binread, blob.download
        assert_empty blob.attachments
        ["#{key}_signed_id", signed_id]
      end

      assert_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'], 1 do
        post admin_paper_applications_path, params: @params.merge(retained).merge(
          identity_review_receipt: css_select('input[name=identity_review_receipt]').sole['value'],
          identity_determination: 'keep_separate', identity_rationale: 'Paper identifies a different person.'
        )
      end
      assert_response :redirect
      application = Application.order(:id).last
      @blobs.each_key { |key| assert_equal retained["#{key}_signed_id"], application.public_send(key).blob.signed_id }
    end

    test 'legacy preview still requires an authenticated admin' do
      sign_out
      post identity_review_admin_paper_applications_path, as: :json
      assert_response :unauthorized

      sign_in_for_integration_test(create(:constituent))
      post identity_review_admin_paper_applications_path, as: :json
      assert_redirected_to root_path
    end

    test 'selecting a related dependent reuses the person and relationship and records the case with the application' do
      guardian = create(:constituent)
      create(:guardian_relationship, guardian_user: guardian, dependent_user: @candidate)
      dependent_params = @params.merge(applicant_type: 'dependent', guardian_id: guardian.id,
                                       relationship_type: 'Parent', email_strategy: 'guardian',
                                       phone_strategy: 'guardian', address_strategy: 'guardian')
      post admin_paper_applications_path, params: dependent_params
      assert_response :unprocessable_content
      receipt = css_select('input[name=identity_review_receipt]').sole['value']

      assert_no_difference ['User.count', 'GuardianRelationship.count'] do
        assert_difference ['Application.count', 'DuplicateReviewCase.count'], 1 do
          post admin_paper_applications_path, params: dependent_params.merge(
            identity_review_receipt: receipt, identity_candidate_id: @candidate.id,
            identity_rationale: 'Guardian confirmed the dependent on file.'
          )
        end
      end
      assert_response :redirect
      application = Application.order(:id).last
      assert_equal @candidate, application.user
      assert_equal guardian, application.managing_guardian
      assert DuplicateReviewCase.order(:id).last.resolved_selected?
    end

    test 'unavailable or already attached signed uploads cannot commit an application or identity decision' do
      post admin_paper_applications_path, params: @params
      receipt = css_select('input[name=identity_review_receipt]').sole['value']
      confirmed = @params.merge(identity_review_receipt: receipt, identity_determination: 'keep_separate',
                                identity_rationale: 'Different person confirmed.')
      expired = @blobs.fetch('income_proof')
      expired.update!(created_at: 8.days.ago)
      foreign_application = create(:application)
      foreign_application.income_proof.attach(@blobs.fetch('residency_proof'))

      ['invalid-signed-id', expired.signed_id, @blobs.fetch('residency_proof').signed_id].each do |signed_id|
        assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count', 'Event.count'] do
          post admin_paper_applications_path, params: confirmed.merge(income_proof_signed_id: signed_id)
        end
        assert_response :unprocessable_content
        assert_select 'input[type=hidden][name=income_proof_signed_id]', count: 0
      end
      assert foreign_application.reload.income_proof.attached?
    end

    test 'select existing requires verification and records selection without creating another person' do
      post admin_paper_applications_path, params: @params
      receipt = css_select('input[name=identity_review_receipt]').sole['value']
      selection = @params.merge(identity_review_receipt: receipt, identity_candidate_id: @candidate.id,
                                identity_rationale: 'Staff confirmed the existing person.', contact_info_mode: 'on_file')
      assert_no_difference ['User.count', 'Application.count', 'DuplicateReviewCase.count'] do
        post admin_paper_applications_path, params: selection
      end
      assert_response :unprocessable_content
      assert_select '#review_contact_verified'

      assert_no_difference 'User.count' do
        assert_difference ['Application.count', 'DuplicateReviewCase.count'], 1 do
          post admin_paper_applications_path, params: selection.merge(contact_info_verified: '1')
        end
      end
      assert_response :redirect
      assert_equal @candidate, Application.order(:id).last.user
      assert DuplicateReviewCase.order(:id).last.resolved_selected?
    end
  end
end
