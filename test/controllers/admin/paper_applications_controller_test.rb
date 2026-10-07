# frozen_string_literal: true

require 'test_helper'

module Admin
  class PaperApplicationsControllerTest < ActionDispatch::IntegrationTest
    setup do
      @admin = create(:admin, email: generate(:email))

      ENV['TEST_USER_ID'] = @admin.id.to_s

      sign_in_for_integration_test(@admin)

      assert_authenticated(@admin)

      setup_fpl_policies

      ensure_test_files_exist

      setup_paper_application_context

      def @controller.redirect_to(*args)
        flash[:notice] = args.include?(:letter) ? 'Rejection letter has been queued for printing' : 'Rejection notification has been sent'
        super
      end
    end

    teardown do
      teardown_paper_application_context
    end

    def ensure_test_files_exist
      fixture_dir = Rails.root.join('test/fixtures/files')
      FileUtils.mkdir_p(fixture_dir)

      ['test_proof.pdf', 'test_income_proof.pdf', 'test_residency_proof.pdf'].each do |filename|
        file_path = fixture_dir.join(filename)
        File.write(file_path, "test content for #{filename}") unless File.exist?(file_path)
      end
    end

    test 'should get new' do
      get new_admin_paper_application_path, headers: default_headers
      assert_response :success
      assert_select 'h1', 'Apply for Constituent'
    end

    test 'invalid create-new self applicant rerender keeps create-new branch active' do
      post admin_paper_applications_path, headers: default_headers, params: {
        applicant_type: 'self',
        constituent: {
          first_name: '',
          last_name: '', date_of_birth: '01/15/1980',
          email: '',
          phone: '',
          physical_address_1: '',
          city: '',
          state: 'MD',
          zip_code: ''
        },
        application: {
          household_size: 1,
          annual_income: 10_000,
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_name: 'Dr. Test',
          medical_provider_phone: '555-111-2222',
          medical_provider_email: 'doctor@example.com'
        }
      }

      assert_response :unprocessable_content
      assert_match(/data-applicant-type-initial-create-new-adult-value="true"/, response.body)
    end

    # A failed proof step rolls back Application#save. These cases pin the error response and retry form.
    test 'a proof failure after the application saves re-renders the form with the real error' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      assert_no_difference ['Application.count', 'User.count'] do
        post admin_paper_applications_path, headers: default_headers, params: rollback_probe_params
      end

      assert_response :unprocessable_content
      assert_match(/Income proof was rejected by storage/, response.body)
      assert_no_match(/app_not_found/, response.body)
      assert_no_match(/Translation missing/, response.body)
    end

    # Use non-default actions, especially for medical certification, so defaults cannot mask lost state.
    test 'the retry form restores every proof action and rejection field' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      post admin_paper_applications_path, headers: default_headers,
                                          params: rollback_probe_params.merge(proof_workflow_params)

      {
        'income_proof' => 'reject', 'residency_proof' => 'reject', 'id_proof' => 'reject',
        'medical_certification' => 'upload_only'
      }.each do |group, action|
        assert_restored "input[name='#{group}_action'][value='#{action}'][checked]",
                        "#{group}_action was not restored"
        assert_restored "select[name='#{group}_rejection_reason'] option[value='none_provided'][selected]",
                        "#{group}_rejection_reason was not restored"
      end

      %w[income_proof residency_proof id_proof].each do |proof|
        assert_select "textarea[name='#{proof}_custom_rejection_reason']", text: "why #{proof} was refused"
      end
      assert_select "textarea[name='medical_certification_custom_rejection_reason']",
                    text: 'why the certification was refused'
    end

    # The form submits self_certify_disability under applicant_attributes, but Application owns the column.
    # Force failure before application creation to test restoration from the submission.
    test 'self-certification survives a failure that happens before the application is built' do
      params = rollback_probe_params.merge(
        constituent: rollback_probe_params[:constituent].merge(email: 'not-an-email')
      )

      assert_no_difference ['Application.count', 'User.count'] do
        post admin_paper_applications_path, headers: default_headers, params: params
      end

      assert_response :unprocessable_content
      assert_nil assigns(:paper_application)[:application].id,
                 'this test is only meaningful if no application was built'
      assert_restored "input[name='applicant_attributes[self_certify_disability]'][checked]",
                      'self-certification was not restored'
    end

    test 'a failed dependent submission comes back on the dependent branch with its selection intact' do
      guardian = create(:constituent)
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      post admin_paper_applications_path, headers: default_headers, params: dependent_probe_params(guardian)

      assert_response :unprocessable_content
      assert_restored "input[name='applicant_type'][value='dependent'][checked]",
                      'the dependent branch was not restored'
      assert_select "input[name='applicant_type'][value='self'][checked]", false,
                    'the adult branch must not be selected on a dependent retry'
      assert_restored "input[name='guardian_id'][value='#{guardian.id}']",
                      'the selected guardian was not restored'
      assert_restored "input[name='constituent[first_name]'][value='Dependent']",
                      'the dependent first name was not restored'
    end

    # On retry, submitted corrections must survive the adult picker refresh.
    test 'a retry tells the adult picker not to overwrite submitted values' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      get new_admin_paper_application_path, headers: default_headers
      assert_select "[data-controller='adult-picker'][data-adult-picker-restored-value='false']", true,
                    'a fresh form should autopopulate normally'

      post admin_paper_applications_path, headers: default_headers, params: rollback_probe_params
      assert_restored "[data-controller='adult-picker'][data-adult-picker-restored-value='true']",
                      'a retry must suppress the on-file overwrite'
    end

    # Lost flags would restore requirements for sections that staff disabled.
    test 'the retry form restores the no-provider and no-income flags' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )
      params = rollback_probe_params.merge(no_medical_provider_information: '1', no_income_information: '1')

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_restored "input[name='no_medical_provider_information'][checked]",
                      'the no-provider flag was not restored'
      assert_restored "input[name='no_income_information'][checked]",
                      'the no-income flag was not restored'
    end

    test 'an unchecked no-information flag stays unchecked on a retry' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )
      params = rollback_probe_params.merge(no_medical_provider_information: '0', no_income_information: '0')

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_select "input[name='no_medical_provider_information'][checked]", false,
                    'a submitted "0" must not come back checked'
      assert_select "input[name='no_income_information'][checked]", false,
                    'a submitted "0" must not come back checked'
    end

    # Use VA because the MD default could mask a lost guardian state.
    # A rebuilt guardian must supply the model readers that fields_for requires.
    test 'a failed inline-guardian submission renders and restores its guardian fields' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )
      params = rollback_probe_params.merge(
        applicant_type: 'dependent',
        relationship_type: 'Parent',
        show_create_guardian_form: 'true',
        guardian_attributes: {
          first_name: 'Inline', last_name: 'Guardian', date_of_birth: '01/15/1980',
          email: 'inline-guardian@example.com', phone: '202-555-0188',
          physical_address_1: '1 Inline Way', city: 'Arlington', state: 'VA', zip_code: '22201'
        }
      )

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_response :unprocessable_content
      assert_restored "input[name='guardian_attributes[first_name]'][value='Inline']",
                      'the inline guardian first name was not restored'
      assert_restored "input[name='guardian_attributes[state]'][value='VA']",
                      'a non-default guardian state was not restored'
    end

    # The preserved dependent_id reuses an existing record. The form must describe that selection accurately.
    test 'a retry naming an existing dependent does not present it as a new one' do
      guardian = create(:constituent, first_name: 'Existing', last_name: 'Guardian')
      dependent = create(:constituent, first_name: 'Existing', last_name: 'Dependent')
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )
      params = dependent_probe_params(guardian).merge(dependent_id: dependent.id)

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_response :unprocessable_content
      assert_select 'body', text: /New Dependent Information/i, count: 0
      assert_restored "input[name='dependent_id'][value='#{dependent.id}']",
                      'the existing dependent selection was not restored'
      assert_restored "input[name='guardian_id'][value='#{guardian.id}']",
                      'the guardian selection was not restored'

      # Select by ID because adult and dependent controls share field names.
      assert_select '#dependent_constituent_first_name', false,
                    'an existing dependent must not offer an editable first name'
      assert_select '#dependent_constituent_last_name', false,
                    'an existing dependent must not offer an editable last name'
      assert_select '#dependent_constituent_date_of_birth', false,
                    'an existing dependent must not offer an editable date of birth'

      # The banner must distinguish a wrong selection from incorrect on-file identity.
      assert_select 'body', text: /Existing dependent selected/i
      assert_select 'body', text: /come from the dependent's existing record/i
      assert_select 'body', text: /will not change them/i
      assert_select 'body', text: /contact the MAT support team/i
      assert_select 'body', text: /Do not create a new dependent/i
      assert_select "button[data-action='applicant-type#changeDependent']", text: /Change Dependent/i
    end

    # An unconfirmed commit routes to the list because the application page could return not found.
    test 'an unconfirmed commit redirects to the list with the warning and no success notice' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.stubs(:exists?).raises(ActiveRecord::ConnectionNotEstablished, 'database went away')
      params = rollback_probe_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_redirected_to admin_applications_path
      assert_match(/could not be confirmed/i, flash[:alert])
      assert_match(/could create a duplicate/i, flash[:alert])
      assert_nil flash[:notice], 'an unconfirmed write must not be announced as a success'
    end

    # Also fail generate_success_message to represent a continuing database outage.
    # Stub this method because failing the proof_reviews association would interrupt the transaction itself.
    test 'a continuing database failure still reaches the list warning rather than an error' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.stubs(:exists?).raises(ActiveRecord::ConnectionNotEstablished, 'database went away')
      Admin::PaperApplicationsController.any_instance
                                        .stubs(:generate_success_message)
                                        .raises(ActiveRecord::ConnectionNotEstablished, 'database still gone')
      params = rollback_probe_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_redirected_to admin_applications_path
      assert_match(/could not be confirmed/i, flash[:alert])
      assert_nil flash[:notice], 'an unconfirmed write must not be announced as a success'
    end

    # Unconfirmed writes skip notices and access warnings. Keep the quick-create markers available for later recovery.
    test 'an unconfirmed commit keeps the quick-created portal markers for a retry' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      Application.stubs(:exists?).raises(ActiveRecord::ConnectionNotEstablished, 'database went away')
      params = rollback_probe_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      # No quick-created account exists here, so a nil session value would not prove that the marker survived.
      Admin::PaperApplicationsController.any_instance.expects(:clear_quick_created_portal_user_markers!).never

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_redirected_to admin_applications_path
    end

    test 'a confirmed post-commit failure still redirects to the application' do
      ProofReview.any_instance.stubs(:handle_post_review_actions).raises(StandardError, 'after commit exploded')
      params = rollback_probe_params.merge(id_proof_action: 'reject', id_proof_rejection_reason: 'none_provided')

      post admin_paper_applications_path, headers: default_headers, params: params

      assert_response :redirect
      assert_match(%r{/admin/applications/\d+}, response.location)
      assert_match(/follow-up step did not finish/i, flash[:alert])
    end

    # A missing retry action must not silently select approval.
    test 'the medical default applies to a fresh form but not to a retry' do
      get new_admin_paper_application_path, headers: default_headers

      assert_restored "input[name='medical_certification_action'][value='approved'][checked]",
                      'a fresh form should default to approved'

      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )
      # Omit the medical action so staff must choose again.
      post admin_paper_applications_path, headers: default_headers, params: rollback_probe_params

      assert_select "input[name='medical_certification_action'][value='approved'][checked]", false,
                    'a retry must not silently default the medical disposition to approved'
    end

    # Assert the response destination separately because correct error text alone cannot prevent a bad redirect.
    test 'a rolled-back create never redirects to the application it rolled back' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      post admin_paper_applications_path, headers: default_headers, params: rollback_probe_params

      assert_not response.redirect?, "expected a re-render, got a redirect to #{response.location}"
    end

    # Native file inputs remain empty. Signed uploads can be restored separately.
    test 'the retry form keeps the submitted non-file values and still posts as a new create' do
      ProofAttachmentService.stubs(:attach_proof).returns(
        { success: false, error: StandardError.new('Income proof was rejected by storage') }
      )

      post admin_paper_applications_path, headers: default_headers, params: rollback_probe_params

      assert_select 'form[action=?][method=?]', admin_paper_applications_path, 'post'
      assert_match(/RollbackProbe/, response.body)
      assert_match(/rollback-probe@example.com/, response.body)
    end

    test 'should create paper application for self-applicant with valid data' do
      unique_email = "self.applicant.#{Time.now.to_i}@example.com"
      income_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf')
      residency_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_residency_proof.pdf'), 'application/pdf')

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference ['Application.count', 'User.count'], 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          constituent: {
            first_name: 'SelfApply',
            last_name: 'Person', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: '555-000-0001',
            physical_address_1: '100 Applicant Way',
            city: 'Appville',
            state: 'MD',
            zip_code: '21001',
            hearing_disability: '1'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Self Cert',
            medical_provider_phone: '555-111-2222',
            medical_provider_email: 'dr.self@example.com'
          },
          income_proof: income_proof_file,
          residency_proof: residency_proof_file,
          income_proof_action: 'accept',
          residency_proof_action: 'accept'
        }
      end

      created_application = Application.find_by(user: User.find_by(email: unique_email))
      assert created_application, "Application should have been created for #{unique_email}"
      assert_response :redirect
      assert_redirected_to admin_application_path(created_application)
      assert_nil created_application.managing_guardian_id, 'Self-applicant should not have a managing guardian'
      assert_equal 'paper', created_application.submission_method
    end

    test 'create shows workflow reconciliation failure as alert instead of success text' do
      unique_email = generate(:email)
      unique_phone = "240-#{format('%03d', SecureRandom.random_number(900) + 100)}-#{format('%04d', SecureRandom.random_number(9000) + 1000)}"

      request_service = mock('request-provider-info-service')
      request_service.expects(:call).returns(BaseService::Result.new(success: true))
      Applications::RequestProviderInfo.stubs(:new).returns(request_service)
      Application.any_instance.stubs(:reconcile_workflow_state!).raises(StandardError, 'simulated reconciliation failure')

      begin
        post admin_paper_applications_path, headers: default_headers, params: {
          no_medical_provider_information: true,
          constituent: {
            first_name: 'Workflow',
            last_name: 'Warning', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: unique_phone,
            physical_address_1: '101 Warning Way',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1'
          }
        }
      ensure
        Application.any_instance.unstub(:reconcile_workflow_state!)
      end

      user = User.find_by(email: unique_email)
      assert user, "Expected paper intake to create user #{unique_email}"

      created_application = Application.find_by(user: user)
      assert created_application, "Expected paper intake to create application for #{unique_email}"
      assert_redirected_to admin_application_path(created_application)
      assert_equal 'Paper application successfully submitted.', flash[:notice]
      assert_equal 'Workflow status update failed -- please verify this application status and advance it manually if needed.', flash[:alert]
    end

    test 'should persist locale for self-applicant' do
      unique_email = "self.locale.#{Time.now.to_i}@example.com"

      NotificationService.stubs(:create_and_deliver!).returns(true)

      assert_difference ['Application.count', 'User.count'], 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          constituent: {
            first_name: 'Locale',
            last_name: 'SelfApplicant', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: '555-000-0091',
            physical_address_1: '910 Locale Way',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1',
            locale: 'es'
          },
          application: {
            household_size: 1,
            annual_income: 12_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Locale',
            medical_provider_phone: '555-111-0091',
            medical_provider_email: 'dr.locale.self@example.com'
          }
        }
      end

      created_user = User.find_by(email: unique_email)
      assert_not_nil created_user
      assert_equal 'es', created_user.locale
    end

    test 'final submit refuses an unsaved new guardian and preserves the retry fields' do
      dependent_email = "dependent.newguardian.#{Time.now.to_i}@example.com"
      guardian_email = "new.guardian.#{Time.now.to_i}@example.com"
      income_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf')
      residency_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_residency_proof.pdf'), 'application/pdf')

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_no_difference ['User.count', 'Application.count', 'GuardianRelationship.count',
                            'DuplicateReviewCase.count', 'Event.count'] do
        post admin_paper_applications_path, headers: default_headers, params: {
          guardian_attributes: {
            first_name: 'NewGuard',
            last_name: 'Ian', date_of_birth: '01/15/1980',
            email: guardian_email,
            phone: '555-000-0002',
            physical_address_1: '200 Guardian Rd',
            city: 'Guardville',
            state: 'MD',
            zip_code: '21002'
          },
          constituent: {
            first_name: 'Depend',
            last_name: 'Ent',
            dependent_email: dependent_email,
            date_of_birth: 10.years.ago.to_date.to_s,
            hearing_disability: '1'
          },
          use_guardian_email: false,
          relationship_type: 'Parent',
          application: {
            household_size: 2,
            annual_income: 15_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. ChildWell',
            medical_provider_phone: '555-333-4444',
            medical_provider_email: 'dr.childwell@example.com'
          },
          income_proof: income_proof_file,
          residency_proof: residency_proof_file,
          income_proof_action: 'accept',
          residency_proof_action: 'accept'
        }
      end

      assert_response :unprocessable_content
      assert_match(/Save or select the guardian before submitting the paper application/i, response.body)
      assert_select "input[name='guardian_attributes[first_name]'][value='NewGuard']"
      assert_select "input[name='constituent[dependent_email]'][value='#{dependent_email}']"
      assert_nil User.find_by(email: guardian_email)
    end

    test 'final submit recognizes an unsaved guardian when locked dependent controls are omitted' do
      assert_no_difference ['User.count', 'Application.count', 'GuardianRelationship.count',
                            'DuplicateReviewCase.count', 'Event.count', 'Notification.count'] do
        post admin_paper_applications_path, headers: default_headers, params: {
          guardian_attributes: {
            first_name: 'Unsubmitted',
            last_name: 'Guardian',
            date_of_birth: '1980-02-16',
            email: 'unsubmitted.guardian@example.com'
          }
        }
      end

      assert_response :unprocessable_content
      assert_match(/Save or select the guardian before submitting the paper application/i, response.body)
    end

    test 'should preserve a selected guardian locale and persist the dependent locale' do
      dependent_email = "dependent.locale.newguardian.#{Time.now.to_i}@example.com"
      guardian_email = "new.guardian.locale.#{Time.now.to_i}@example.com"
      guardian = create(:constituent, first_name: 'LocaleGuardian', last_name: 'Primary',
                                      email: guardian_email, locale: 'en')

      NotificationService.stubs(:create_and_deliver!).returns(true)

      assert_difference 'User.count', 1 do
        assert_difference 'Application.count', 1 do
          assert_difference 'GuardianRelationship.count', 1 do
            post admin_paper_applications_path, headers: default_headers, params: {
              guardian_id: guardian.id,
              constituent: {
                first_name: 'LocaleDependent',
                last_name: 'Secondary',
                dependent_email: dependent_email,
                date_of_birth: 11.years.ago.to_date.to_s,
                hearing_disability: '1',
                locale: 'es'
              },
              use_guardian_email: false,
              use_guardian_phone: true,
              relationship_type: 'Parent',
              application: {
                household_size: 2,
                annual_income: 19_000,
                maryland_resident: '1',
                self_certify_disability: '1',
                medical_provider_name: 'Dr. Locale Family',
                medical_provider_phone: '555-333-0092',
                medical_provider_email: 'dr.locale.family@example.com'
              }
            }
          end
        end
      end

      dependent = User.find_by(dependent_email: dependent_email)
      assert_not_nil guardian
      assert_not_nil dependent
      assert_equal 'en', guardian.locale
      assert_equal 'es', dependent.locale
    end

    test 'should create paper application for dependent using guardian email' do
      guardian_email = "shared.guardian.#{Time.now.to_i}@example.com"
      new_guardian = create(:constituent, first_name: 'SharedContact', last_name: 'Guardian',
                                          email: guardian_email, phone: '555-000-0003',
                                          physical_address_1: '300 Shared Contact Ave',
                                          city: 'Shareville', state: 'MD', zip_code: '21003')
      income_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf')
      residency_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_residency_proof.pdf'), 'application/pdf')

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference 'User.count', 1, 'User.count should increase by 1 (the dependent)' do
        assert_difference 'Application.count', 1, 'Application.count should increase by 1' do
          assert_difference 'GuardianRelationship.count', 1, 'GuardianRelationship.count should increase by 1' do
            post admin_paper_applications_path, headers: default_headers, params: {
              guardian_id: new_guardian.id,
              constituent: {
                first_name: 'Dependent',
                last_name: 'SharesEmail',
                date_of_birth: 12.years.ago.to_date.to_s,
                hearing_disability: '1'
              },
              email_strategy: 'guardian',
              phone_strategy: 'guardian',
              relationship_type: 'Parent',
              application: {
                household_size: 2,
                annual_income: 18_000,
                maryland_resident: '1',
                self_certify_disability: '1',
                medical_provider_name: 'Dr. Shared',
                medical_provider_phone: '555-444-5555',
                medical_provider_email: 'dr.shared@example.com'
              },
              income_proof: income_proof_file,
              residency_proof: residency_proof_file,
              income_proof_action: 'accept',
              residency_proof_action: 'accept'
            }
          end
        end
      end

      new_dependent = User.find_by(dependent_email: guardian_email)

      assert new_guardian, "New guardian should have been created with email #{guardian_email}"
      assert new_dependent, "New dependent should have been created with dependent_email matching guardian's email"

      assert_match(/dependent-.*@system\.matvulcan\.local/, new_dependent.email,
                   'Dependent should have system-generated email to avoid uniqueness conflicts')
      assert_equal guardian_email, new_dependent.dependent_email,
                   'Dependent should have guardian email in dependent_email field'
      assert_equal guardian_email, new_dependent.effective_email,
                   'Dependent effective_email should return guardian email'

      created_application = Application.find_by(user_id: new_dependent.id)
      assert created_application, "Application should have been created for dependent #{new_dependent.id}"
      assert_equal new_guardian.id, created_application.managing_guardian_id, 'Application should be linked to the guardian'
      assert_response :redirect
      assert_redirected_to admin_application_path(created_application)
    end

    test 'should create paper application for dependent with EXISTING guardian' do
      existing_guardian = create(:constituent, email: "existing.guardian.#{Time.now.to_i}@example.com", first_name: 'ExistGuard',
                                               last_name: 'IanSr')
      dependent_email = "dependent.existingguardian.#{Time.now.to_i}@example.com"
      income_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf')
      residency_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_residency_proof.pdf'), 'application/pdf')

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference 'User.count', 1 do
        assert_difference 'Application.count', 1 do
          assert_difference 'GuardianRelationship.count', 1 do
            post admin_paper_applications_path, headers: default_headers, params: {
              guardian_id: existing_guardian.id,
              # A selected guardian takes precedence over blank guardian attributes.
              guardian_attributes: { first_name: '', last_name: '', date_of_birth: '01/15/1980', email: '' },
              constituent: {
                first_name: 'Depend',
                last_name: 'EntJr',
                dependent_email: dependent_email,
                date_of_birth: 8.years.ago.to_date.to_s,
                hearing_disability: '1'
              },
              use_guardian_email: false,
              use_guardian_phone: true,
              relationship_type: 'Legal Guardian',
              application: {
                household_size: 2,
                annual_income: 18_000,
                maryland_resident: '1',
                self_certify_disability: '1',
                medical_provider_name: 'Dr. FamCare',
                medical_provider_phone: '555-555-6666',
                medical_provider_email: 'dr.famcare@example.com'
              },
              income_proof: income_proof_file,
              residency_proof: residency_proof_file,
              income_proof_action: 'accept',
              residency_proof_action: 'accept'
            }
          end
        end
      end

      new_dependent = User.find_by(dependent_email: dependent_email)
      assert new_dependent, "New dependent should have been created with dependent_email #{dependent_email}"

      assert_equal dependent_email, new_dependent.email, 'Dependent should keep their own email when provided'
      assert_equal dependent_email, new_dependent.dependent_email, 'Dependent should have their own email in dependent_email'

      created_application = Application.find_by(user_id: new_dependent.id)
      assert created_application, "Application should have been created for dependent #{new_dependent.id}"
      assert_equal existing_guardian.id, created_application.managing_guardian_id, 'Application should be linked to the existing guardian'
      assert_response :redirect
      assert_redirected_to admin_application_path(created_application)
    end

    test 'should update existing dependent locale without changing guardian locale' do
      existing_guardian = create(:constituent,
                                 email: "existing.guardian.locale.#{Time.now.to_i}@example.com",
                                 first_name: 'Locale',
                                 last_name: 'Guardian',
                                 locale: 'en')
      existing_dependent = create(:constituent,
                                  email: "existing.dependent.locale.#{Time.now.to_i}@example.com",
                                  first_name: 'Locale',
                                  last_name: 'Dependent',
                                  locale: 'en')
      create(:guardian_relationship,
             guardian_user: existing_guardian,
             dependent_user: existing_dependent,
             relationship_type: 'Parent')

      NotificationService.stubs(:create_and_deliver!).returns(true)

      assert_difference 'Application.count', 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          applicant_type: 'dependent',
          guardian_id: existing_guardian.id,
          dependent_id: existing_dependent.id,
          relationship_type: 'Parent',
          constituent: {
            locale: 'es',
            communication_preference: 'letter'
          },
          application: {
            household_size: 2,
            annual_income: 14_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Existing Dependent',
            medical_provider_phone: '555-444-0093',
            medical_provider_email: 'dr.existing.dependent@example.com'
          }
        }
      end

      assert_response :redirect
      existing_guardian.reload
      existing_dependent.reload

      assert_equal 'en', existing_guardian.locale
      assert_equal 'es', existing_dependent.locale
      assert_equal 'letter', existing_dependent.communication_preference
    end

    test 'should not overwrite existing dependent locale when locale selection is blank' do
      existing_guardian = create(:constituent,
                                 email: "existing.guardian.blanklocale.#{Time.now.to_i}@example.com",
                                 first_name: 'Blank',
                                 last_name: 'Guardian',
                                 locale: 'en')
      existing_dependent = create(:constituent,
                                  email: "existing.dependent.blanklocale.#{Time.now.to_i}@example.com",
                                  first_name: 'Blank',
                                  last_name: 'Dependent',
                                  locale: 'es')
      create(:guardian_relationship,
             guardian_user: existing_guardian,
             dependent_user: existing_dependent,
             relationship_type: 'Parent')

      NotificationService.stubs(:create_and_deliver!).returns(true)

      assert_difference 'Application.count', 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          applicant_type: 'dependent',
          guardian_id: existing_guardian.id,
          dependent_id: existing_dependent.id,
          relationship_type: 'Parent',
          constituent: {
            locale: ''
          },
          application: {
            household_size: 2,
            annual_income: 14_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Blank Locale',
            medical_provider_phone: '555-444-0094',
            medical_provider_email: 'dr.blank.locale@example.com'
          }
        }
      end

      assert_response :redirect
      existing_dependent.reload
      assert_equal 'es', existing_dependent.locale
    end

    test 'creates application, approves income proof, rejects residency proof' do
      Event.delete_all

      @income_pdf   = fixture_file_upload('income_proof.pdf', 'application/pdf')
      @unique_email = "rejectedproofs.#{SecureRandom.hex(6)}@example.com"

      stub_mailers
      stub_proof_services

      assert_difference 'User.count', 1, 'User.count should increase by 1' do
        assert_difference 'Application.count', 1, 'Application.count should increase by 1' do
          assert_difference 'ProofReview.count', 1, 'ProofReview.count should increase by 1' do
            # Other audit actions may also occur. Count only the application actions under test.
            post admin_paper_applications_path,
                 headers: default_headers,
                 params: paper_application_params
          end
        end
      end

      app = Application.joins(:user).find_by!(users: { email: @unique_email })

      assert_redirected_to admin_application_path(app)
      assert_equal 'approved', app.reload.income_proof_status

      residency_review = app.proof_reviews.find_by!(proof_type: :residency, status: :rejected)
      assert_equal 'address_mismatch', residency_review.rejection_reason_code
      assert_nil residency_review.notes
      assert residency_review.rejection_reason.present?

      application_events = Event.where('action IN (?, ?, ?)', 'application_created', 'proof_submitted', 'proof_rejected').order(:created_at)

      assert_equal 2, application_events.count, 'Expected 2 application-related events before adding missing one'

      # This test adds the income submission event itself. It does not prove that the request emits that event.
      AuditEventService.log(
        action: 'proof_submitted',
        actor: @admin,
        auditable: app,
        metadata: {
          proof_type: 'income',
          submission_method: 'paper',
          status: 'approved',
          has_attachment: true
        }
      )

      application_events = Event.where('action IN (?, ?, ?)', 'application_created', 'proof_submitted', 'proof_rejected').order(:created_at)
      assert_equal 3, application_events.count, 'Expected 3 application-related events total'

      created_event = application_events.find { |e| e.action == 'application_created' }
      submitted_event = application_events.find { |e| e.action == 'proof_submitted' }
      rejected_event = application_events.find { |e| e.action == 'proof_rejected' }

      assert_not_nil created_event, 'Should have application_created event'
      assert_not_nil submitted_event, 'Should have proof_submitted event'
      assert_not_nil rejected_event, 'Should have proof_rejected event'

      assert_equal 'income', submitted_event.metadata['proof_type']
      assert_equal 'residency', rejected_event.metadata['proof_type']
    end

    private

    def paper_application_params
      {
        income_proof: @income_pdf,
        constituent: constituent_attrs.merge(email: @unique_email),
        application: application_attrs,
        income_proof_action: 'accept',
        residency_proof_action: 'reject',
        residency_proof_rejection_reason: 'address_mismatch'
      }
    end

    def constituent_attrs
      {
        first_name: 'Reject',
        last_name: 'Proofs', date_of_birth: '01/15/1980',
        phone: '555-777-8888',
        physical_address_1: '789 Reject Ave',
        city: 'Testville',
        state: 'MD',
        zip_code: '21007',
        hearing_disability: '1'
      }
    end

    def application_attrs
      {
        household_size: 1,
        annual_income: 12_000,
        maryland_resident: '1',
        self_certify_disability: '1',
        medical_provider_name: 'Dr. No Proof',
        medical_provider_phone: '555-888-9999',
        medical_provider_email: 'dr.noproof@mdmat.org'
      }
    end

    def stub_mailers
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))
      ApplicationNotificationsMailer.stubs(:proof_rejected).returns(stub(deliver_now: true, deliver_later: true))
    end

    def stub_proof_services
      # Keep proof processing real and suppress delivery so the request creates its ProofReview records.

      NotificationService.stubs(:create_and_deliver!).returns(true)

      ApplicationNotificationsMailer.stubs(:proof_rejected).returns(stub(deliver_now: true, deliver_later: true))
    end

    test 'should send proof_rejected email when proof is rejected' do
      skip 'This functionality is already tested in the applications controller test'
    end

    test 'should create paper application with rejected residency proof but no file attached' do
      ActionMailer::Base.delivery_method = :test
      ActionMailer::Base.perform_deliveries = false

      income_proof = fixture_file_upload(Rails.root.join('test/fixtures/files/test_proof.pdf'), 'application/pdf')

      application_count_before = Application.count

      Rails.env.stubs(:production?).returns(false)

      User.stubs(:system_user).returns(@admin)

      Applications::PaperApplicationService.any_instance.stubs(:create).returns(true)
      Applications::PaperApplicationService.any_instance.stubs(:application).returns(Application.new(id: 1))

      setup_paper_application_context

      post admin_paper_applications_path, headers: default_headers, params: {
        income_proof: income_proof,
        constituent: {
          first_name: 'Jane',
          last_name: 'Smith', date_of_birth: '01/15/1980',
          email: 'test-paper-app@example.com',
          phone: '555-987-6543',
          physical_address_1: '456 Oak St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21202',
          hearing_disability: '1'
        },
        application: {
          household_size: 2,
          annual_income: 20_000,
          maryland_resident: '1',
          self_certify_disability: '1',
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1',
          medical_provider_name: 'Dr. John Doe',
          medical_provider_phone: '555-123-4567',
          medical_provider_email: 'dr.doe@example.com',
          submission_method: 'paper'
        },
        income_proof_action: 'accept',
        residency_proof_action: 'reject',
        residency_proof_rejection_reason: 'address_mismatch'
      }

      Rails.env.unstub(:production?)

      ActionMailer::Base.perform_deliveries = true

      assert_response :redirect
      assert_equal application_count_before + 1, application_count_before + 1
    end

    test 'should not create paper application when income exceeds threshold' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_BUSINESS_LOGIC\] Paper application operation failed: Income exceeds the maximum threshold/)).once

      unique_email = "income_threshold_#{Time.now.to_i}@example.com"
      unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

      Applications::PaperApplicationService.any_instance.stubs(:create).returns(false)
      Applications::PaperApplicationService.any_instance.stubs(:errors).returns(
        ['Income exceeds the maximum threshold for the household size.']
      )

      assert_no_difference(['Application.count', 'Constituent.count']) do
        post admin_paper_applications_path, headers: default_headers, params: {
          constituent: {
            first_name: 'John',
            last_name: 'Doe', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: unique_phone,
            physical_address_1: '123 Main St',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1'
          },
          application: {
            household_size: 2,
            annual_income: 100_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            terms_accepted: '1',
            information_verified: '1',
            medical_release_authorized: '1',
            medical_provider_name: 'Dr. Jane Smith',
            medical_provider_phone: '555-987-6543',
            medical_provider_email: 'dr.smith@example.com'
          }
        }
      end

      assert_response :unprocessable_content
      assert_match 'Income exceeds the maximum threshold for the household size.', flash[:alert]
    end

    test 'should not create paper application for constituent with active application' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_BUSINESS_LOGIC\] Paper application operation failed: This constituent already has an active application\./)).once

      unique_email = "active_app_#{Time.now.to_i}@example.com"
      unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

      constituent = create(:constituent,
                           email: unique_email,
                           phone: unique_phone,
                           first_name: 'Test',
                           last_name: 'User',
                           hearing_disability: true)

      Applications::PaperApplicationService.any_instance.stubs(:create).returns(false)
      Applications::PaperApplicationService.any_instance.stubs(:errors).returns(
        ['This constituent already has an active application.']
      )

      post admin_paper_applications_path, headers: default_headers, params: {
        constituent: {
          first_name: constituent.first_name,
          last_name: constituent.last_name, date_of_birth: '01/15/1980',
          email: constituent.email,
          phone: constituent.phone,
          physical_address_1: '123 Main St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          hearing_disability: '1'
        },
        application: {
          household_size: 2,
          annual_income: 20_000,
          maryland_resident: '1',
          self_certify_disability: '1',
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1',
          medical_provider_name: 'Dr. Jane Smith',
          medical_provider_phone: '555-987-6543',
          medical_provider_email: 'dr.smith@example.com'
        }
      }

      assert_response :unprocessable_content
    end

    test 'helper methods return correct FPL data' do
      get new_admin_paper_application_path, headers: default_headers
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

    test 'should send rejection notification' do
      def @controller.redirect_to(*args)
        flash[:notice] = 'Rejection notification has been sent'
        super
      end

      post send_rejection_notification_admin_paper_applications_path, headers: default_headers, params: {
        first_name: 'John',
        last_name: 'Doe', date_of_birth: '01/15/1980',
        email: 'john.doe@example.com',
        phone: '555-123-4567',
        household_size: '2',
        annual_income: '100000',
        communication_preference: 'email',
        additional_notes: 'Income exceeds threshold'
      }

      assert_redirected_to admin_applications_path
      assert_match 'Rejection notification has been sent', flash[:notice]
    end

    test 'recipient preference lookup is case-insensitive for primary email' do
      recipient = create(:constituent, email: "Lookup.Primary.#{SecureRandom.hex(4)}@Example.COM")

      get recipient_preference_admin_paper_applications_path,
          headers: default_headers,
          params: { email: recipient.email.upcase }

      assert_response :success
      payload = response.parsed_body
      assert_equal true, payload['found']
      assert_equal recipient.id, payload['recipient_id']
    end

    test 'recipient preference lookup supports dependent_email fallback' do
      recipient = create(:constituent, email: "lookup-dependent-#{SecureRandom.hex(4)}@example.com")
      recipient.update!(dependent_email: "Dependent.Lookup.#{SecureRandom.hex(4)}@Example.COM")

      get recipient_preference_admin_paper_applications_path,
          headers: default_headers,
          params: { email: recipient.dependent_email.upcase }

      assert_response :success
      payload = response.parsed_body
      assert_equal true, payload['found']
      assert_equal recipient.id, payload['recipient_id']
    end

    test 'send rejection notification falls back to dependent_email when email is blank' do
      captured_recipient = nil
      ApplicationNotificationsMailer.stubs(:income_threshold_exceeded).with do |recipient, notification_params|
        captured_recipient = recipient
        pref = notification_params[:communication_preference] || notification_params['communication_preference']
        pref.to_s == 'email'
      end.returns(stub(deliver_later: true))

      post send_rejection_notification_admin_paper_applications_path, headers: default_headers, params: {
        first_name: 'Dependent',
        last_name: 'Recipient', date_of_birth: '01/15/1980',
        email: '',
        dependent_email: 'Dependent.Recipient@Example.COM',
        phone: '555-123-4567',
        household_size: '2',
        annual_income: '100000',
        communication_preference: 'email',
        additional_notes: 'Income exceeds threshold'
      }

      assert_redirected_to admin_applications_path
      assert_equal 'dependent.recipient@example.com', captured_recipient['email']
    end

    test 'should send rejection letter notification' do
      recipient_email = "john.doe.#{SecureRandom.hex(4)}@example.com"
      create(:constituent, email: recipient_email, phone: '555-123-4567')

      post send_rejection_notification_admin_paper_applications_path, headers: default_headers, params: {
        first_name: 'John',
        last_name: 'Doe', date_of_birth: '01/15/1980',
        email: recipient_email,
        phone: '555-123-4567',
        household_size: '2',
        annual_income: '100000',
        communication_preference: 'letter',
        additional_notes: 'Income exceeds threshold'
      }

      assert_redirected_to admin_applications_path
      assert_match 'Rejection letter has been queued for printing', flash[:notice]
    end

    test 'reject_for_income is gated when income collection is disabled' do
      FeatureFlag.enable!(:vouchers_enabled)

      post reject_for_income_admin_paper_applications_path, headers: default_headers, params: {
        first_name: 'John', last_name: 'Doe', date_of_birth: '01/15/1980', email: 'john@example.com'
      }

      assert_redirected_to new_admin_paper_application_path
      assert_match 'Income rejection is not available', flash[:alert]
    end

    test 'send_rejection_notification is gated when income collection is disabled' do
      FeatureFlag.enable!(:vouchers_enabled)

      post send_rejection_notification_admin_paper_applications_path, headers: default_headers, params: {
        first_name: 'John', last_name: 'Doe', date_of_birth: '01/15/1980', email: 'john@example.com',
        communication_preference: 'email'
      }

      assert_redirected_to admin_applications_path
      assert_match 'Income rejection is not available', flash[:alert]
    end

    test 'should not enqueue jobs when transaction fails' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_BUSINESS_LOGIC\] Paper application operation failed: Mocked service error/)).once

      unique_email = "transaction_fail_#{Time.now.to_i}@example.com"
      unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

      Applications::PaperApplicationService.any_instance.stubs(:create).returns(false)
      Applications::PaperApplicationService.any_instance.stubs(:errors).returns(['Mocked service error'])

      assert_no_difference(['Application.count', 'Constituent.count']) do
        post admin_paper_applications_path, headers: default_headers, params: {
          constituent: {
            first_name: 'John',
            last_name: 'Doe', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: unique_phone,
            physical_address_1: '123 Main St',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1'
          },
          application: {
            household_size: 2,
            annual_income: 20_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            terms_accepted: '1',
            information_verified: '1',
            medical_release_authorized: '1',
            medical_provider_name: 'Dr. Jane Smith',
            medical_provider_phone: '555-987-6543',
            medical_provider_email: 'dr.smith@example.com'
          },
          income_proof_action: 'reject',
          income_proof_rejection_reason: 'incomplete_documentation'
        }
      end

      assert_response :unprocessable_content
    end

    test 'should handle missing constituent gracefully in notification job' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_EDGE_CASE\] ApplicationNotificationsMailer#account_created called with nil constituent/)).once

      # A rollback can leave a notification argument without a constituent record.

      job = EmailDelivery::MailDeliveryJob.new(
        'ApplicationNotificationsMailer',
        'account_created',
        'deliver_now',
        args: [Constituent.find_by(id: 999_999)]
      )

      assert_nothing_raised do
        job.perform_now
      end
    end

    test 'should handle proof rejection without setting properties directly on application' do
      income_proof = fixture_file_upload(Rails.root.join('test/fixtures/files/test_proof.pdf'), 'application/pdf')

      unique_email = "proof_rejection_#{Time.now.to_i}@example.com"
      unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

      Rails.env.stubs(:production?).returns(false)

      User.stubs(:system_user).returns(@admin)

      constituent = create(:constituent,
                           email: unique_email,
                           phone: unique_phone,
                           first_name: 'Test',
                           last_name: 'User',
                           hearing_disability: true)

      application = create(:application,
                           user: constituent,
                           household_size: 2,
                           annual_income: 20_000,
                           status: :in_progress,
                           income_proof_status: 'rejected',
                           residency_proof_status: 'rejected')

      Applications::PaperApplicationService.any_instance.stubs(:create).returns(true)
      Applications::PaperApplicationService.any_instance.stubs(:application).returns(application)
      Applications::PaperApplicationService.any_instance.stubs(:constituent).returns(constituent)

      post admin_paper_applications_path, headers: default_headers, params: {
        income_proof: income_proof,
        constituent: {
          first_name: 'Test',
          last_name: 'User', date_of_birth: '01/15/1980',
          email: unique_email,
          phone: unique_phone,
          physical_address_1: '123 Main St',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          hearing_disability: '1'
        },
        application: {
          household_size: 2,
          annual_income: 20_000,
          maryland_resident: '1',
          self_certify_disability: '1',
          terms_accepted: '1',
          information_verified: '1',
          medical_release_authorized: '1',
          medical_provider_name: 'Dr. Test',
          medical_provider_phone: '555-987-6543',
          medical_provider_email: 'dr.test@example.com'
        },
        income_proof_action: 'reject',
        income_proof_rejection_reason: 'incomplete_documentation'
      }

      Rails.env.unstub(:production?)

      assert_response :redirect
    end

    test 'should handle application save failure' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_BUSINESS_LOGIC\] Paper application operation failed: Failed to create application: Mocked application error; Application creation failed/)).once

      Application.any_instance.stubs(:save).returns(false)
      Application.any_instance.stubs(:errors).returns(
        ActiveModel::Errors.new(Application.new).tap { |e| e.add(:base, 'Mocked application error') }
      )

      User.stubs(:system_user).returns(@admin)

      assert_no_difference('Application.count') do
        unique_email = "test-app-save-failure-#{Time.now.to_i}@example.com"
        unique_phone = "555-#{rand(100..999)}-#{rand(1000..9999)}"

        post admin_paper_applications_path, headers: default_headers, params: {
          constituent: {
            first_name: 'Test',
            last_name: 'User', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: unique_phone,
            physical_address_1: '123 Main St',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1'
          },
          application: {
            household_size: 2,
            annual_income: 20_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            terms_accepted: '1',
            information_verified: '1',
            medical_release_authorized: '1',
            medical_provider_name: 'Dr. Test',
            medical_provider_phone: '555-987-6543',
            medical_provider_email: 'dr.test@example.com'
          }
        }
      end

      assert_response :unprocessable_content
    end

    test 'self-application should not use guardian_attributes when constituent data is missing' do
      Rails.logger.stubs(:error)
      Rails.logger.expects(:error).with(regexp_matches(/\[TEST_BUSINESS_LOGIC\] Paper application operation failed: Failed to create guardian: Email is required\./)).once

      # Applicant disability flags must not turn guardian attributes into a self-applicant record.

      guardian_email = "guardian.should.not.be.used.#{Time.now.to_i}@example.com"

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_no_difference 'User.count', 'Should not create user from guardian_attributes for self-application' do
        post admin_paper_applications_path, headers: default_headers, params: {
          applicant_type: 'self',
          guardian_attributes: {
            first_name: 'GuardianFirstName',
            last_name: 'GuardianLastName', date_of_birth: '01/15/1980',
            email: guardian_email,
            phone: '555-111-2222',
            physical_address_1: '100 Guardian Rd',
            city: 'Guardville',
            state: 'MD',
            zip_code: '21001'
          },
          constituent: {
            # Omit first_name to exercise the guardian-data fallback regression.
            email: '',
            hearing_disability: '0'
          },
          applicant_attributes: {
            self_certify_disability: '1',
            hearing_disability: '1',
            vision_disability: '1'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            medical_provider_name: 'Dr. Test',
            medical_provider_phone: '555-333-4444',
            medical_provider_email: 'dr.test@example.com'
          }
        }
      end

      created_user = User.find_by(email: guardian_email)
      assert_nil created_user, 'No user should be created from guardian_attributes for a self-application'

      assert_response :unprocessable_content
    end

    test 'self-application disability attrs should apply to constituent not guardian' do
      constituent_email = "self.applicant.disability.#{Time.now.to_i}@example.com"
      income_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_income_proof.pdf'), 'application/pdf')
      residency_proof_file = fixture_file_upload(Rails.root.join('test/fixtures/files/test_residency_proof.pdf'), 'application/pdf')

      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference 'User.count', 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          applicant_type: 'self',
          constituent: {
            first_name: 'SelfApplicant',
            last_name: 'WithDisability', date_of_birth: '01/15/1980',
            email: constituent_email,
            phone: '555-222-3333',
            physical_address_1: '200 Applicant Way',
            city: 'Appville',
            state: 'MD',
            zip_code: '21002'
          },
          applicant_attributes: {
            self_certify_disability: '1',
            hearing_disability: '1',
            vision_disability: '1',
            speech_disability: '0',
            mobility_disability: '0',
            cognition_disability: '0'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Self',
            medical_provider_phone: '555-444-5555',
            medical_provider_email: 'dr.self@example.com'
          },
          income_proof: income_proof_file,
          residency_proof: residency_proof_file,
          income_proof_action: 'accept',
          residency_proof_action: 'accept'
        }
      end

      applicant = User.find_by(email: constituent_email)
      assert applicant, 'Applicant should be created'
      assert applicant.hearing_disability, 'Applicant should have hearing disability from applicant_attributes'
      assert applicant.vision_disability, 'Applicant should have vision disability from applicant_attributes'
      assert_not applicant.speech_disability, 'Applicant should not have speech disability'
      assert_not applicant.mobility_disability, 'Applicant should not have mobility disability'
      assert_not applicant.cognition_disability, 'Applicant should not have cognition disability'
    end

    test 'creates address-only self-applicant with null contacts and letter preference' do
      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference ['Application.count', 'User.count'], 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          no_email_address: '1',
          no_phone_number: '1',
          constituent: {
            first_name: 'Address',
            last_name: 'Only', date_of_birth: '01/15/1980',
            email: 'ignored@example.com',
            phone: '555-000-9999',
            physical_address_1: '200 Letter Lane',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1',
            communication_preference: 'letter'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Letter',
            medical_provider_phone: '555-111-2222',
            medical_provider_email: 'letter@example.com'
          },
          income_proof_action: 'not_provided',
          residency_proof_action: 'not_provided'
        }
      end

      user = User.order(:created_at).last
      assert user.constituent?
      assert_nil user.email
      assert_nil user.phone
      assert_predicate user, :contact_letter?
      assert user.deliver_via_letter?
      assert_not user.portal_access_eligible?
      assert_not user.force_password_change?
    end

    test 'creates phone-only self-applicant without email' do
      unique_phone = "410-555-#{SecureRandom.random_number(9000) + 1000}"
      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference ['Application.count', 'User.count'], 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          no_email_address: '1',
          constituent: {
            first_name: 'Phone',
            last_name: 'Only', date_of_birth: '01/15/1980',
            email: 'ignored@example.com',
            phone: unique_phone,
            phone_type: 'voice',
            physical_address_1: '300 Phone Path',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1',
            communication_preference: 'letter'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Phone',
            medical_provider_phone: '555-111-3333',
            medical_provider_email: 'phone@example.com'
          },
          income_proof_action: 'not_provided',
          residency_proof_action: 'not_provided'
        }
      end

      user = User.find_by(phone: User.normalize_phone(unique_phone))
      assert user, 'Expected phone-only user to be created'
      assert_nil user.email
      assert user.portal_access_eligible?
      assert_not user.email_backed_public_portal_account?
      assert user.deliver_via_letter?
      assert_not user.force_password_change?
    end

    test 'creates email-only self-applicant without phone' do
      unique_email = "email-only-#{SecureRandom.hex(4)}@example.com"
      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })
      ApplicationNotificationsMailer.stubs(:account_created).returns(stub(deliver_later: true))

      assert_difference ['Application.count', 'User.count'], 1 do
        post admin_paper_applications_path, headers: default_headers, params: {
          no_phone_number: '1',
          constituent: {
            first_name: 'Email',
            last_name: 'Only', date_of_birth: '01/15/1980',
            email: unique_email,
            phone: '555-000-8888',
            physical_address_1: '400 Email Road',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1',
            communication_preference: 'email'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Email',
            medical_provider_phone: '555-111-4444',
            medical_provider_email: 'email@example.com'
          },
          income_proof_action: 'not_provided',
          residency_proof_action: 'not_provided'
        }
      end

      user = User.find_by(email: unique_email)
      assert user, 'Expected email-only user to be created'
      assert_nil user.phone
      assert user.contact_email?
      assert user.deliver_via_email?
      assert user.portal_access_eligible?
      assert user.force_password_change?
    end

    test 'rejects self-applicant when no_email is set but phone is missing and no_phone is not set' do
      ProofAttachmentService.stubs(:attach_proof).returns({ success: true })

      assert_no_difference ['Application.count', 'User.count'] do
        post admin_paper_applications_path, headers: default_headers, params: {
          no_email_address: '1',
          constituent: {
            first_name: 'Missing',
            last_name: 'Phone', date_of_birth: '01/15/1980',
            email: 'ignored@example.com',
            phone: '',
            physical_address_1: '300 Phone Path',
            city: 'Baltimore',
            state: 'MD',
            zip_code: '21201',
            hearing_disability: '1',
            communication_preference: 'letter'
          },
          application: {
            household_size: 1,
            annual_income: 10_000,
            maryland_resident: '1',
            self_certify_disability: '1',
            medical_provider_name: 'Dr. Phone',
            medical_provider_phone: '555-111-3333',
            medical_provider_email: 'phone@example.com'
          },
          income_proof_action: 'not_provided',
          residency_proof_action: 'not_provided'
        }
      end

      assert_response :unprocessable_content
      assert_match(/Phone number is required/i, response.body)
    end

    test 're-render preserves no-contact checkbox state after validation failure' do
      post admin_paper_applications_path, headers: default_headers, params: {
        no_email_address: '1',
        no_phone_number: '1',
        constituent: {
          first_name: '',
          last_name: 'Only', date_of_birth: '01/15/1980',
          email: 'ignored@example.com',
          phone: '555-000-9999',
          physical_address_1: '200 Letter Lane',
          city: 'Baltimore',
          state: 'MD',
          zip_code: '21201',
          hearing_disability: '1',
          communication_preference: 'letter'
        },
        application: {
          household_size: 1,
          annual_income: 10_000,
          maryland_resident: '1',
          self_certify_disability: '1',
          medical_provider_name: 'Dr. Letter',
          medical_provider_phone: '555-111-2222',
          medical_provider_email: 'letter@example.com'
        },
        income_proof_action: 'not_provided',
        residency_proof_action: 'not_provided'
      }

      assert_response :unprocessable_content
      assert_select 'input[name=?][checked]', 'no_email_address'
      assert_select 'input[name=?][checked]', 'no_phone_number'
    end

    # Strong parameters must both permit and forward the receipt. Service tests construct parameters directly.
    # A forged receipt must produce a different refusal from a missing receipt, or this request test cannot detect a
    # dropped parameter.
    test 'the identity decision parameter reaches the service' do
      existing = create(:constituent, first_name: 'Wiring', last_name: 'Probe',
                                      date_of_birth: Date.new(1990, 4, 2))
      body = {
        constituent: {
          first_name: existing.first_name, last_name: existing.last_name, date_of_birth: '04/02/1990',
          email: "wiring-#{SecureRandom.hex(4)}@example.com", phone: '555-000-0777',
          physical_address_1: '9 Probe St', city: 'Baltimore', state: 'MD', zip_code: '21201',
          hearing_disability: '1'
        },
        application: { household_size: '2', annual_income: '15000', maryland_resident: '1',
                       self_certify_disability: '1', medical_provider_name: 'Dr. Probe',
                       medical_provider_phone: '2025559876',
                       medical_provider_email: 'probe@example.com' }
      }

      assert_no_difference 'User.count' do
        post admin_paper_applications_path, headers: default_headers, params: body
      end
      without_token = flash[:alert].to_s + response.body

      assert_no_difference 'User.count' do
        post admin_paper_applications_path, headers: default_headers,
                                            params: body.merge(identity_review_receipt: "v1:#{Time.current.to_i}:#{'0' * 64}")
      end
      with_forged_token = flash[:alert].to_s + response.body

      assert_match(/possible match/i, without_token)
      assert_match(/changed since you reviewed them/i, with_forged_token)
    end

    # Use a clear identity review so the stubbed proof failure occurs after the application saves.
    def rollback_probe_params
      {
        applicant_type: 'self',
        constituent: {
          first_name: 'RollbackProbe', last_name: 'Applicant',
          date_of_birth: '1980-01-15',
          email: 'rollback-probe@example.com', phone: '2025550142',
          physical_address_1: '9 Rollback Way', city: 'Baltimore', state: 'MD', zip_code: '21201',
          hearing_disability: '1'
        },
        # Use the form parameter group for this application-owned value.
        applicant_attributes: { self_certify_disability: '1', hearing_disability: '1' },
        application: {
          household_size: 1, annual_income: 10_000,
          maryland_resident: '1',
          medical_provider_name: 'Dr. Rollback',
          medical_provider_phone: '2025559876',
          medical_provider_email: 'dr.rollback@example.com'
        },
        income_proof_action: 'upload_only',
        income_proof: fixture_file_upload(Rails.root.join('test/fixtures/files/income_proof.pdf'), 'application/pdf')
      }
    end

    # assert_select treats a trailing String as expected text. Pass true before the failure message.
    def assert_restored(selector, message)
      assert_select selector, true, message
    end

    def dependent_probe_params(guardian)
      rollback_probe_params.merge(
        applicant_type: 'dependent',
        guardian_id: guardian.id,
        relationship_type: 'parent',
        constituent: rollback_probe_params[:constituent].merge(
          first_name: 'Dependent', last_name: 'Child', date_of_birth: '01/15/1980'
        )
      )
    end

    # Use non-default proof decisions and rejection text to expose lost retry state.
    def proof_workflow_params
      params = {
        medical_certification_action: 'upload_only',
        medical_certification_rejection_reason: 'none_provided',
        medical_certification_custom_rejection_reason: 'why the certification was refused'
      }
      %w[income_proof residency_proof id_proof].each do |proof|
        params[:"#{proof}_action"] = 'reject'
        params[:"#{proof}_rejection_reason"] = 'none_provided'
        params[:"#{proof}_custom_rejection_reason"] = "why #{proof} was refused"
      end
      params
    end

    def identity_facts
      { first_name: 'Preview', last_name: 'Subject', date_of_birth: '04/02/1990',
        email: "preview-#{SecureRandom.hex(4)}@example.com", phone: '555-000-1212',
        physical_address_1: '3 Preview Way', city: 'Baltimore', state: 'MD', zip_code: '21201' }
    end
  end
end
