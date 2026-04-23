# frozen_string_literal: true

require 'test_helper'
require_relative 'email_template_mock_helper'

class ApplicationNotificationsMailerTest < ActionMailer::TestCase
  include ActiveJob::TestHelper
  include EmailTemplateMockHelper
  include Mailers::ApplicationNotificationsHelper

  setup do
    setup_email_template_mocks
    setup_email_template_stubs
    create_test_data
    stub_url_helpers
    stub_shared_partial_helpers
    set_expected_subjects
    set_application_and_reapply_dates
    clear_emails
  end

  private

  def setup_email_template_mocks
    @mock_approved_text = mock_template('Mock Proof Approved: Income',
                                        'Text Body: Income approved for %<user_first_name>s.')
    @mock_rejected_text = mock_template('Mock Proof Needs Revision: Income',
                                        'Text Body: Income needs revision for %<user_first_name>s. ' \
                                        'Reason: %<rejection_reason>s')
    @mock_max_reached = mock_template('Mock Application Archived - ID 7',
                                      '<p>HTML Body: Application 7 archived for John. ' \
                                      'Reapply after May 15, 2028.</p>')
    @mock_max_reached_text = mock_template('Mock Application Archived - ID 7',
                                           'Text Body: Application %<application_id>s archived for ' \
                                           '%<user_first_name>s. Reapply after %<reapply_date_formatted>s.')
    @mock_reminder = mock_template('Mock Reminder: %<stale_reviews_count>s Apps Need Review',
                                   '<p>HTML Body: Reminder for %<admin_full_name>s. ' \
                                   '%<stale_reviews_count>s apps need review. %<stale_reviews_html_table>s</p>')
    @mock_reminder_text = mock_template('Mock Reminder: %<stale_reviews_count>s Apps Need Review',
                                        'Text Body: Reminder for %<admin_full_name>s. ' \
                                        '%<stale_reviews_count>s apps need review. %<stale_reviews_text_list>s')
    @mock_account_created = mock_template('Mock Account Created for %<constituent_first_name>s',
                                          '<p>HTML Body: Welcome %<constituent_first_name>s! Your password is ' \
                                          '%<temp_password>s. Sign in: %<sign_in_url>s</p>')
    @mock_account_created_text = mock_template('Mock Account Created for %<constituent_first_name>s',
                                               'Text Body: Welcome %<constituent_first_name>s! Your password is ' \
                                               '%<temp_password>s. Sign in: %<sign_in_url>s')
    @mock_income_exceeded = mock_template('Mock Income Threshold Exceeded for %<constituent_first_name>s',
                                          '<p>HTML Body: %<constituent_first_name>s, your income ' \
                                          '%<annual_income_formatted>s exceeds the threshold ' \
                                          '%<threshold_formatted>s for household size %<household_size>s.</p> ' \
                                          '%<additional_notes>s')
    @mock_income_exceeded_text = mock_template('Mock Income Threshold Exceeded for %<constituent_first_name>s',
                                               'Text Body: %<constituent_first_name>s, your income ' \
                                               '%<annual_income_formatted>s exceeds the threshold ' \
                                               '%<threshold_formatted>s for household size %<household_size>s. ' \
                                               '%<additional_notes>s')
    @mock_registration = mock_template('Mock Welcome Jane!',
                                       '<p>HTML Body: Welcome, Jane! Dashboard: http://example.com/dashboard. ' \
                                       'New App: http://example.com/applications/new</p>')
    @mock_registration_text = mock_template('Mock Welcome Jane!',
                                            'Text Body: Welcome, Jane! Dashboard: http://example.com/dashboard. ' \
                                            'New App: http://example.com/applications/new. ' \
                                            'No authorized vendors found at this time.')
    @mock_training_requested_text = mock_template('Training Requested for Application #%<application_id>s',
                                                  'Training requested by %<constituent_full_name>s for application %<application_id>s.')
  end

  def setup_email_template_stubs
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_approved', format: :text, locale: 'en').returns(@mock_approved_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_rejected', format: :text, locale: 'en').returns(@mock_rejected_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_max_rejections_reached', format: :text, locale: 'en').returns(@mock_max_reached_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_needs_review_reminder', format: :text, locale: 'en').returns(@mock_reminder_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_account_created', format: :text, locale: 'en').returns(@mock_account_created_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_income_threshold_exceeded', format: :text, locale: 'en').returns(@mock_income_exceeded_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_registration_confirmation', format: :text, locale: 'en').returns(@mock_registration_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_training_requested', format: :text, locale: 'en').returns(@mock_training_requested_text)
  end

  def create_test_data
    @application = create(:application)
    @user = @application.user
    @proof_review = create(:proof_review, :with_income_proof, application: @application, rejection_reason: 'Document unclear')
    @admin = create(:admin)
  end

  def stub_url_helpers
    ApplicationNotificationsMailer.any_instance.stubs(:sign_in_url).returns('http://example.com/users/sign_in')
    ApplicationNotificationsMailer.any_instance.stubs(:login_url).returns('http://example.com/users/sign_in')
    ApplicationNotificationsMailer.any_instance.stubs(:new_user_session_url).returns('http://example.com/users/sign_in')
    ApplicationNotificationsMailer.any_instance.stubs(:constituent_portal_dashboard_url).returns('http://example.com/dashboard')
    ApplicationNotificationsMailer.any_instance.stubs(:new_constituent_portal_application_url).returns('http://example.com/applications/new')
    # Scope the stub to the mailer instance so Mocha auto-teardowns it and
    # no other test's admin_applications_path(filter: ...) calls are affected.
    ApplicationNotificationsMailer.any_instance.stubs(:admin_applications_path).returns('/admin/applications')
    ApplicationNotificationsMailer.any_instance.stubs(:admin_application_url).with(anything, anything).returns('http://example.com/admin/applications/1')
  end

  def stub_shared_partial_helpers
    ApplicationNotificationsMailer.any_instance.stubs(:header_html).returns('<div>Mock Header HTML</div>')
    ApplicationNotificationsMailer.any_instance.stubs(:header_text).returns('Mock Header Text')
    ApplicationNotificationsMailer.any_instance.stubs(:footer_html).returns('<div>Mock Footer HTML</div>')
    ApplicationNotificationsMailer.any_instance.stubs(:footer_text).returns('Mock Footer Text')
    ApplicationNotificationsMailer.any_instance.stubs(:status_box_html).with(any_parameters).returns('<div>Mock Status Box HTML</div>')
    ApplicationNotificationsMailer.any_instance.stubs(:status_box_text).with(any_parameters).returns('Mock Status Box Text')
  end

  def set_expected_subjects
    @expected_subjects = {
      'proof_approved' => 'Mock Proof Approved: income',
      'proof_rejected' => 'Mock Proof Needs Revision: income',
      'max_rejections_reached' => 'Mock Application Archived - ID 7',
      'proof_needs_review_reminder' => 'Mock Reminder: 1 Apps Need Review',
      'account_created' => 'Mock Account Created for John',
      'income_threshold_exceeded' => 'Mock Income Threshold Exceeded for John',
      'registration_confirmation' => 'Mock Welcome Jane!'
    }
  end

  def set_application_and_reapply_dates
    @application.update_column(:needs_review_since, 4.days.ago)
    @reapply_date = 3.years.from_now.to_date
  end

  def clear_emails
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    # Clean up after each test
    ActionMailer::Base.deliveries.clear
  end

  test 'proof_approved' do
    # Set default mail parameters to ensure consistency
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    # Call the mailer method and deliver the email
    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.proof_approved(@application, @proof_review)
      email.deliver_now
    end

    # Now check the email's basic properties
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to

    # Check the actual delivered email content in ActionMailer::Base.deliveries
    delivered_email = ActionMailer::Base.deliveries.first
    assert_equal 'Mock Proof Approved: Income', delivered_email.subject

    # Check the content of the email
    assert_match(/approved for #{@user.first_name}/, delivered_email.body.to_s)
    assert_match(/Income/, delivered_email.body.to_s)
  end

  test 'training_requested sends an application-owned admin email' do
    admin = create(:admin, email: 'training_request_admin@example.com')
    notification = create(:notification,
                          recipient: admin,
                          actor: @application.user,
                          notifiable: @application,
                          action: 'training_requested')
    @application.update_column(:training_requested_at, Time.current)

    email = ApplicationNotificationsMailer.training_requested(@application, notification)
    email.deliver_now

    assert_equal [admin.email], email.to
    assert_equal "Training Requested for Application ##{@application.id}", email.subject
    assert_match(@application.user.full_name, email.body.to_s)
  end

  test 'proof_approved uses guardian locale and email when communications route to guardian' do
    guardian = create(:constituent,
                      email: "guardian.mailer.locale.#{SecureRandom.hex(3)}@example.com",
                      locale: 'es')
    dependent = create(:constituent,
                       email: "dependent.mailer.system.#{SecureRandom.hex(3)}@system.matvulcan.local",
                       dependent_email: guardian.email,
                       locale: 'en')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

    application = create(:application, user: dependent, managing_guardian: guardian)
    proof_review = create(:proof_review, :with_income_proof, application: application, rejection_reason: 'Documento borroso')

    spanish_template = mock_template('Asunto de prueba en espanol',
                                     'Texto de prueba para %<user_first_name>s')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_proof_approved',
      format: :text,
      locale: 'es'
    ).returns(spanish_template)

    email = ApplicationNotificationsMailer.proof_approved(application, proof_review)
    email.deliver_now

    assert_equal [guardian.email], email.to
    assert_equal 'Asunto de prueba en espanol', email.subject
  end

  test 'proof_approved uses dependent locale and email when communications route to dependent' do
    guardian = create(:constituent,
                      email: "guardian.mailer.locale.#{SecureRandom.hex(3)}@example.com",
                      locale: 'es')
    dependent_email = "dependent.mailer.locale.#{SecureRandom.hex(3)}@example.com"
    dependent = create(:constituent,
                       email: dependent_email,
                       dependent_email: dependent_email,
                       locale: 'en')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')
    assert_equal dependent.email, dependent.effective_email

    application = create(:application, user: dependent, managing_guardian: guardian)
    proof_review = create(:proof_review, :with_income_proof, application: application, rejection_reason: 'Document unclear')

    english_template = mock_template('Dependent locale subject',
                                     'Dependent locale body for %<user_first_name>s')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_proof_approved',
      format: :text,
      locale: 'en'
    ).returns(english_template)

    email = ApplicationNotificationsMailer.proof_approved(application, proof_review)
    email.deliver_now

    assert_equal [dependent.email], email.to
    assert_equal 'Dependent locale subject', email.subject
  end

  test 'proof_approved routes to Spanish letter when user prefers letter and has Spanish locale' do
    @user.update!(communication_preference: 'letter', locale: 'es')

    spanish_template = mock_template('Documento Aprobado: Ingreso',
                                     'Texto: Ingreso aprobado para %<user_first_name>s.')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_proof_approved',
      format: :text,
      locale: 'es'
    ).returns(spanish_template)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with(
      has_entries(template_name: 'application_notifications_proof_approved')
    ).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.proof_approved(@application, @proof_review)
    assert_no_emails { delivery.deliver_now }
  end

  test 'proof_rejected' do
    # Set up the remaining_attempts for the test
    @application.update_column(:total_rejections, 3)

    # Set default mail parameters to ensure consistency
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    # Deliver the email directly with deliver_now instead of deliver_later
    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.proof_rejected(@application, @proof_review)
      email.deliver_now
    end

    # Assert email properties
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to

    # We're working with the mock data from setup
    expected_subject = "Mock Proof Needs Revision: #{format_proof_type(@proof_review.proof_type).capitalize}"
    assert_equal expected_subject, email.subject

    # We're using a text-only template, don't expect multipart emails anymore
    assert_not email.multipart?

    # Check the content of the email
    assert_includes email.body.to_s, "needs revision for #{@user.first_name}"
    assert_includes email.body.to_s, "Reason: #{@proof_review.rejection_reason}"
  end

  test 'proof_rejected sends to guardian email when dependent communications route to guardian' do
    guardian = create(:constituent,
                      email: "guardian.rejected.locale.#{SecureRandom.hex(3)}@example.com",
                      locale: 'es')
    dependent = create(:constituent,
                       email: "dependent.rejected.system.#{SecureRandom.hex(3)}@system.matvulcan.local",
                       dependent_email: guardian.email,
                       locale: 'en')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent, relationship_type: 'Parent')

    application = create(:application, user: dependent, managing_guardian: guardian, total_rejections: 2)
    proof_review = create(:proof_review, :with_income_proof, application: application, rejection_reason: 'Document unclear')

    spanish_template = mock_template('Rechazo en espanol',
                                     'Texto de rechazo para %<user_first_name>s. ' \
                                     'Reason: %<rejection_reason>s ' \
                                     '%<remaining_attempts_message_text>s ' \
                                     '%<default_options_text>s')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_proof_rejected',
      format: :text,
      locale: 'es'
    ).returns(spanish_template)

    email = ApplicationNotificationsMailer.proof_rejected(application, proof_review)
    email.deliver_now

    assert_equal [guardian.email], email.to
    assert_equal 'Rechazo en espanol', email.subject
    assert_includes email.body.to_s, 'Tiene 6 intentos restantes'
    assert_includes email.body.to_s, I18n.l(3.years.from_now.to_date, format: :long, locale: 'es')
    assert_includes email.body.to_s, 'CÓMO VOLVER A ENVIAR SU DOCUMENTACIÓN'
  end

  test 'proof_rejected generates letter when preference is letter' do
    @user.update!(communication_preference: 'letter')
    @application.update_column(:total_rejections, 3)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.proof_rejected(@application, @proof_review)
    assert_no_emails do
      delivery.deliver_now
    end
  end

  test 'max_rejections_reached' do
    # Set default mail parameters to ensure consistency
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    # Deliver the email directly with deliver_now instead of deliver_later
    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.max_rejections_reached(@application)
      email.deliver_now
    end

    # Assert email properties
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to

    # We're working with the mock data from setup
    expected_subject = 'Mock Application Archived - ID 7'
    assert_equal expected_subject, email.subject

    # We're using a text-only template, don't expect multipart emails anymore
    assert_not email.multipart?

    # Check the content of the email
    assert_includes email.body.to_s, "archived for #{@user.first_name}"
    assert_includes email.body.to_s, "Reapply after #{@reapply_date.strftime('%B %d, %Y')}"
  end

  test 'max_rejections_reached generates letter when preference is letter' do
    @user.update!(communication_preference: 'letter')

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.max_rejections_reached(@application)
    assert_no_emails do
      delivery.deliver_now
    end
  end

  test 'proof_needs_review_reminder' do
    # Create a list of applications that need review
    applications = [@application]

    # Stub the needs_review_since method to return a date more than 3 days ago
    # This is needed for the @stale_reviews to be populated
    @application.stubs(:needs_review_since).returns(4.days.ago)

    # Set default mail parameters to ensure consistency
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    # Use the capture_emails helper instead of assert_emails
    emails = capture_emails do
      ApplicationNotificationsMailer.proof_needs_review_reminder(@admin, applications).deliver_now
    end

    # Verify we captured exactly one email
    assert_equal 1, emails.size
    email = emails.first

    # Test email content
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@admin.email], email.to
    # Assert against specific mock subject
    expected_subject = "Mock Reminder: #{applications.count} Apps Need Review"
    assert_equal expected_subject, email.subject

    # We're using a text-only template, don't expect multipart emails anymore
    assert_not email.multipart?

    # Check the content of the email
    assert_includes email.body.to_s, "Reminder for #{@admin.full_name}"
    assert_includes email.body.to_s, "#{applications.count} apps need review"
    assert_includes email.body.to_s, "ID: #{@application.id}" # Check list content
  end

  test 'account_created' do
    constituent = Constituent.create!(
      first_name: 'John',
      last_name: 'Doe',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      password: 'password',
      password_confirmation: 'password',
      hearing_disability: true
    )
    temp_password = 'temporary123'

    # Set default mail parameters to ensure consistency
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    # Deliver the email directly with deliver_now instead of deliver_later
    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.account_created(constituent, temp_password)
      email.deliver_now
    end

    # Assert email properties
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [constituent.email], email.to

    # We're working with the mock data from setup
    expected_subject = "Mock Account Created for #{constituent.first_name}"
    assert_equal expected_subject, email.subject

    # We're using a text-only template, don't expect multipart emails anymore
    assert_not email.multipart?

    # Check the content of the email
    assert_includes email.body.to_s, "Welcome #{constituent.first_name}"
    assert_includes email.body.to_s, "password is #{temp_password}"
    assert_includes email.body.to_s, 'http://example.com/users/sign_in' # Check sign_in_url
  end

  test 'account_created generates letter when preference is letter' do
    constituent = Constituent.create!(
      first_name: 'John',
      last_name: 'Doe',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      password: 'password',
      password_confirmation: 'password',
      hearing_disability: true,
      communication_preference: 'letter', # Set preference to letter
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    )
    temp_password = 'temporary123'

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.account_created(constituent, temp_password)
    assert_no_emails do
      delivery.deliver_now
    end
  end

  # Helper method to set up common data for income threshold tests
  def setup_income_threshold_test_data
    @constituent_params = {
      first_name: 'John',
      last_name: 'Doe',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      communication_preference: 'letter' # Set preference to letter
    }

    @notification_params = {
      household_size: 2,
      annual_income: 100_000,
      communication_preference: 'email', # This preference is for the email, not the letter recipient
      additional_notes: 'Income exceeds threshold'
    }

    # Set up FPL policies for testing (needed by the mailer method)
    Policy.find_or_create_by(key: 'fpl_2_person').update(value: 20_000)
    Policy.find_or_create_by(key: 'fpl_modifier_percentage').update(value: 400)
  end

  test 'income_threshold_exceeded generates letter when preference is letter' do
    setup_income_threshold_test_data

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.income_threshold_exceeded(
      @constituent_params,
      @notification_params.merge(communication_preference: 'letter')
    )
    assert_no_emails do
      delivery.deliver_now
    end
  end

  test 'income_threshold_exceeded' do
    setup_income_threshold_test_data
    @constituent_params[:communication_preference] = 'email'

    # Create new mocks for the test to ensure they're fresh
    mock_income_exceeded_text = mock_template("Mock Income Threshold Exceeded for #{@constituent_params[:first_name]}",
                                              "Text Body: #{@constituent_params[:first_name]}, your income exceeds the " \
                                              "threshold for household size #{@notification_params[:household_size]}. " \
                                              "#{@notification_params[:additional_notes]}")

    # Re-stub the EmailTemplate.find_by! to return our new mock
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_income_threshold_exceeded',
                                        format: :text, locale: 'en').returns(mock_income_exceeded_text)

    # Set default mail parameters to ensure consistency
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    # Deliver the email directly with deliver_now instead of deliver_later
    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.income_threshold_exceeded(@constituent_params, @notification_params)
      email.deliver_now
    end

    # Assert email properties
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent_params[:email]], email.to

    # We're working with the mock data from setup
    expected_subject = "Mock Income Threshold Exceeded for #{@constituent_params[:first_name]}"
    assert_equal expected_subject, email.subject

    # We're using a text-only template, don't expect multipart emails anymore
    assert_not email.multipart?

    # Check the content of the email
    assert_includes email.body.to_s, "#{@constituent_params[:first_name]}, your income"
    assert_includes email.body.to_s, "household size #{@notification_params[:household_size]}"
    assert_includes email.body.to_s, @notification_params[:additional_notes] # Check optional note
  end

  test 'proof_submission_error generates letter when preference is letter' do
    # Use the existing user to avoid validation problems
    @user.update!(
      communication_preference: 'letter', # Set preference to letter
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    )
    error_message = 'Invalid document format'

    # Create new mocks for the test
    mock_error_text = mock('EmailTemplate')
    mock_error_text.stubs(:name).returns('application_notifications_proof_submission_error')
    mock_error_text.stubs(:subject).returns('Submission Error: %<constituent_full_name>s')
    mock_error_text.stubs(:enabled?).returns(true)
    mock_error_text.stubs(:render).returns(["Submission Error: #{@user.email}",
                                            "Text Body: Error processing submission: #{error_message}"])

    # Re-stub the EmailTemplate.find_by! to return our new mock
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_submission_error',
                                        format: :text, locale: 'en').returns(mock_error_text)

    # Create a mock for the TextTemplateToPdfService instance
    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once

    # Stub the new method to return our mock
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.proof_submission_error(
      @user, # Use existing user
      @application, # Use the application from setup
      :invalid_format,
      error_message
    )
    assert_no_emails do
      delivery.deliver_now
    end
  end

  test 'registration_confirmation' do
    # Create a test constituent
    user = Constituent.create!(
      first_name: 'Jane',
      last_name: 'Smith',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      password: 'password',
      password_confirmation: 'password',
      hearing_disability: true
    )

    # Stub Vendor.active.order to return an empty array
    active_vendors = []
    Vendor.stubs(:active).returns(Vendor.none)
    Vendor.none.stubs(:order).returns(active_vendors)

    # Override the email template mock specifically for this test
    mock_template(
      'Mock Welcome Jane!',
      'Text Body: Welcome, Jane! Dashboard: http://example.com/dashboard. ' \
      'New App: http://example.com/applications/new. No authorized vendors found at this time.'
    )

    # Generate the email
    email = ApplicationNotificationsMailer.registration_confirmation(user)

    # Deliver the email directly (don't use deliver_later)
    assert_emails 1 do
      email.deliver_now
    end

    # Test email attributes
    assert_equal ['no_reply@mdmat.org'], email.from, 'Email should be from no_reply@mdmat.org'
    assert_equal [user.email], email.to, 'Email should be sent to the registered user'
    assert_equal 'Mock Welcome Jane!', email.subject, 'Email subject should match mock'

    # We're using a text-only template, don't expect multipart emails anymore
    assert_not email.multipart?, 'Email should not be multipart'

    # Check the content of the email
    text_content = email.body.to_s
    assert_match 'Welcome, Jane!', text_content
    assert_match 'Dashboard: http://example.com/dashboard', text_content
    assert_match 'New App: http://example.com/applications/new', text_content
    assert_match 'No authorized vendors found at this time.', text_content
  end

  test 'registration_confirmation generates letter when preference is letter' do
    # Create a test constituent with letter preference
    user = Constituent.create!(
      first_name: 'Jane',
      last_name: 'Smith',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      password: 'password',
      password_confirmation: 'password',
      hearing_disability: true,
      communication_preference: 'letter', # Set preference to letter
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    )

    # Stub Vendor.active.order to return an empty array (needed by the mailer method)
    active_vendors = []
    Vendor.stubs(:active).returns(Vendor.none)
    Vendor.none.stubs(:order).returns(active_vendors)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.registration_confirmation(user)
    assert_no_emails do
      delivery.deliver_now
    end
  end

  test 'with_mailer_error_handling suppresses re-raise outside test when configured' do
    mailer = ApplicationNotificationsMailer.new
    production_env = ActiveSupport::StringInquirer.new('production')

    Rails.stubs(:env).returns(production_env)

    result = mailer.send(:with_mailer_error_handling, 'test-context', raise_in_test_only: true) do
      raise StandardError, 'simulated failure'
    end

    assert_nil result
  end

  test 'with_mailer_error_handling still re-raises in test when configured' do
    mailer = ApplicationNotificationsMailer.new
    test_env = ActiveSupport::StringInquirer.new('test')

    Rails.stubs(:env).returns(test_env)

    assert_raises(StandardError) do
      mailer.send(:with_mailer_error_handling, 'test-context', raise_in_test_only: true) do
        raise StandardError, 'simulated failure'
      end
    end
  end
end
