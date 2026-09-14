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

  test 'secure request email uses persisted delivery owner locale' do
    owner = create(:constituent, locale: 'es')
    recipient = create(:constituent, locale: 'en')
    application = create(:application, user: recipient)
    form = create(:secure_request_form, application: application, recipient: recipient,
                                        recipient_email: owner.email, delivery_owner: owner,
                                        delivery_source: 'managing_guardian')
    spanish_template = mock_template('Spanish delivery owner', 'Spanish message for %<user_first_name>s')
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_provider_info_requested',
                                        format: :text, locale: 'es').returns(spanish_template)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_provider_info_requested',
                                        format: :text, locale: 'en').returns(@mock_requested_text)

    mail = ApplicationNotificationsMailer.provider_info_requested(application, form, secure_url: 'https://example.test/secure').deliver_now

    assert_equal [owner.email], mail.to
    assert_equal 'Spanish delivery owner', mail.subject
    assert_includes mail.body.decoded, 'Spanish message'
  end

  %i[proof_requested proof_rejected].each do |action|
    test "#{action} email uses persisted owner language and safe default locale" do
      owner = create(:constituent, locale: 'es')
      recipient = create(:constituent, locale: 'en')
      form = create(:secure_request_form, application: @application, recipient: recipient,
                                          kind: :income_proof_resubmission, delivery_owner: owner,
                                          recipient_email: owner.email, delivery_source: 'managing_guardian')
      %w[es en].each do |locale|
        template = mock_template("#{locale} delivery", "#{locale} message %<proof_type_formatted>s")
        EmailTemplate.stubs(:find_by!).with(name: "application_notifications_#{action}",
                                            format: :text, locale: locale).returns(template)
      end
      %w[es unsupported].each do |locale|
        owner.update!(locale: locale)
        form.reload
        argument = action == :proof_requested ? :income : @proof_review
        mail = ApplicationNotificationsMailer.public_send(action, @application, argument,
                                                          recipient: recipient, secure_request_form: form,
                                                          secure_upload_url: 'https://example.test/secure').deliver_now
        expected_locale = locale == 'es' ? 'es' : I18n.default_locale.to_s
        assert_equal [owner.email], mail.to
        assert_equal "#{expected_locale} delivery", mail.subject
        assert_includes mail.body.decoded, "#{expected_locale} message"
        assert_includes mail.body.decoded, I18n.t('secure_proof_forms.proof_types.income', locale: expected_locale)
      end
    end
  end

  test 'secure request letters render provider and both proof states in the delivery owner language' do
    EmailTemplate.unstub(:find_by!)
    %i[header_text footer_text].each { |helper| ApplicationNotificationsMailer.any_instance.unstub(helper) }
    %w[email_header_text email_footer_text].each do |template_name|
      EmailTemplate.where(name: template_name, format: :text).destroy_all
      %w[en es].each do |locale|
        suffix = locale == 'es' ? '_es' : ''
        load Rails.root.join("db/seeds/email_templates/#{template_name}#{suffix}.rb")
      end
    end
    %w[provider_info_requested proof_requested proof_rejected].each do |action|
      EmailTemplate.where(name: "application_notifications_#{action}", format: :text).destroy_all
      %w[en es].each do |locale|
        suffix = locale == 'es' ? '_es' : ''
        load Rails.root.join("db/seeds/email_templates/application_notifications_#{action}#{suffix}.rb")
      end
    end
    recipient = create(:constituent, locale: 'en')
    owner = create(:constituent, locale: 'es', physical_address_1: '9 Guardian Way')
    %w[en es].each do |locale|
      owner.update!(locale: locale)
      %i[provider_info_requested proof_requested proof_rejected].each do |action|
        form = create(:secure_request_form, application: @application, recipient: recipient,
                                            kind: action == :provider_info_requested ? :provider_info_request : :income_proof_resubmission,
                                            recipient_channel: :letter, recipient_email: nil, recipient_phone: nil,
                                            delivery_owner: owner, delivery_source: 'managing_guardian')
        delivery = if action == :provider_info_requested
                     ApplicationNotificationsMailer.provider_info_requested(@application, form, letter_recipient: owner)
                   else
                     argument = action == :proof_requested ? :income : @proof_review
                     ApplicationNotificationsMailer.public_send(action, @application, argument,
                                                                recipient: recipient, secure_request_form: form,
                                                                letter_recipient: owner)
                   end
        assert_difference('PrintQueueItem.count', 1) { assert_no_emails { delivery.deliver_now } }
        item = PrintQueueItem.order(:created_at).last
        assert_equal owner.id, item.constituent_id
        pdf_path = Rails.root.join("tmp/capybara/secure-request-#{action}-#{locale}.pdf")
        pdf_path.dirname.mkpath
        File.binwrite(pdf_path, item.pdf_letter.download)
        File.write(pdf_path.sub_ext('.json'), JSON.pretty_generate(
                                                generated_at: Time.current.iso8601, target_root: Rails.root.to_s,
                                                test_class: self.class.name, test_name: name, delivery_owner_id: owner.id,
                                                locale: locale, action: action, pdf_path: pdf_path.to_s
                                              ))
        assert_operator pdf_path.size, :>, 1_000
        unless action == :provider_info_requested
          pdf_text = inflated_pdf_text(item.pdf_letter.download)
          assert_includes pdf_text, I18n.t('secure_proof_forms.proof_types.income', locale: locale)
        end
        form.revoke!(actor: @admin, reason: :replacement_request)
      end
    end
  end

  private

  def setup_email_template_mocks
    @mock_approved_text = mock_template('Mock Proof Approved: Income',
                                        'Text Body: Income approved for %<user_first_name>s.')
    @mock_rejected_text = mock_template('Mock Proof Needs Revision: Income',
                                        'Text Body: Income needs revision for %<user_first_name>s. ' \
                                        'Reason: %<rejection_reason>s ' \
                                        '%<default_options_text>s')
    @mock_requested_text = mock_template('Mock Proof Requested: %<proof_type_formatted>s',
                                         'Text Body: Please submit %<proof_type_formatted>s. ' \
                                         '%<default_options_text>s')
    @mock_received_text = mock_template('Mock Proof Received: %<proof_type_formatted>s',
                                        'Text Body: Received %<proof_type_formatted>s for %<user_first_name>s.')
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
                                          '<p>HTML Body: Welcome %<constituent_first_name>s! ' \
                                          'Contact %<support_email>s. Website: %<program_website_url>s</p>')
    @mock_account_created_text = mock_template('Mock Account Created for %<constituent_first_name>s',
                                               "Text Body: Welcome %<constituent_first_name>s!\n" \
                                               "Contact %<support_email>s.\n\n" \
                                               "MAT program website:\n%<program_website_url>s")
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
                                            "Text Body: Welcome, Jane!\n\n" \
                                            "Dashboard link:\nhttp://example.com/dashboard\n\n" \
                                            "New application link:\nhttp://example.com/applications/new\n\n" \
                                            'No authorized vendors found at this time.')
    @mock_training_requested_text = mock_template('Training Requested for Application #%<application_id>s',
                                                  'Training requested by %<constituent_full_name>s for application %<application_id>s.')
    @mock_security_key_recovery_text = mock_template('Security Key Recovery Approved',
                                                     "Recovery approved for %<user_first_name>s.\n\n" \
                                                     "Sign in:\n%<sign_in_url>s")
    @mock_application_submitted_text = mock_template('Application Submitted',
                                                     'Application submitted for %<constituent_first_name>s.')
  end

  def setup_email_template_stubs
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_approved', format: :text, locale: 'en').returns(@mock_approved_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_rejected', format: :text, locale: 'en').returns(@mock_rejected_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_requested', format: :text, locale: 'en').returns(@mock_requested_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_received', format: :text, locale: 'en').returns(@mock_received_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_max_rejections_reached', format: :text, locale: 'en').returns(@mock_max_reached_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_proof_needs_review_reminder', format: :text, locale: 'en').returns(@mock_reminder_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_account_created', format: :text, locale: 'en').returns(@mock_account_created_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_income_threshold_exceeded', format: :text, locale: 'en').returns(@mock_income_exceeded_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_registration_confirmation', format: :text, locale: 'en').returns(@mock_registration_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_training_requested', format: :text, locale: 'en').returns(@mock_training_requested_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_security_key_recovery_approved', format: :text, locale: 'en').returns(@mock_security_key_recovery_text)
    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_application_submitted', format: :text, locale: 'en').returns(@mock_application_submitted_text)
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
    # The mailer-scoped stub preserves other tests' admin_applications_path(filter: ...) calls and allows Mocha cleanup.
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
    ActionMailer::Base.deliveries.clear
  end

  test 'proof_approved' do
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.proof_approved(@application, @proof_review)
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to

    delivered_email = ActionMailer::Base.deliveries.first
    assert_equal 'Mock Proof Approved: Income', delivered_email.subject

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

  test 'training_requested uses English template for Spanish locale admin' do
    admin = create(:admin, email: 'spanish_training_request_admin@example.com', locale: 'es')
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
  end

  test 'application_submitted does not cc alternate contact' do
    @application.update_column(:alternate_contact_email, 'alternate.mailer@example.com')

    email = ApplicationNotificationsMailer.application_submitted(@application)
    email.deliver_now

    assert_equal [@application.user.email], email.to
    assert_nil email.cc
  end

  test 'application_submitted queues letter from a real Liquid text template' do
    EmailTemplate.unstub(:find_by!)
    @user.update!(communication_preference: 'letter')
    create_real_text_email_template(
      name: 'application_notifications_application_submitted',
      subject: 'Submitted {{ application_id }} on {{ submission_date_formatted }}',
      body: 'Hello {{ user_first_name }}, application {{ application_id }} was submitted on {{ submission_date_formatted }}.',
      required: %w[application_id submission_date_formatted user_first_name]
    )

    delivery = ApplicationNotificationsMailer.application_submitted(@application)

    assert_difference -> { PrintQueueItem.count }, 1 do
      assert_no_emails { delivery.deliver_now }
    end

    print_queue_item = PrintQueueItem.last
    assert_equal @user, print_queue_item.constituent
    assert_equal @application, print_queue_item.application
    assert_predicate print_queue_item.pdf_letter, :attached?
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
    @application.update_column(:total_rejections, 3)

    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.proof_rejected(@application, @proof_review)
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to

    assert_equal @mock_rejected_text.subject, email.subject

    assert_not email.multipart?

    assert_includes email.body.to_s, "needs revision for #{@user.first_name}"
    assert_includes email.body.to_s, "Reason: #{@proof_review.rejection_reason}"
  end

  test 'proof_requested includes secure upload url for paper application email delivery' do
    @application.update!(submission_method: :paper)
    @user.update!(communication_preference: :email)
    secure_upload_url = 'https://example.test/secure_proof_form?token=abc'

    email = ApplicationNotificationsMailer.proof_requested(
      @application,
      :id,
      secure_upload_url: secure_upload_url
    )
    email.deliver_now

    assert_equal [@user.email], email.to
    assert_includes decoded_text_part(email), secure_upload_url
    assert_includes decoded_text_part(email), 'Secure proof upload link'
  end

  test 'proof_rejected includes secure upload url for paper application email delivery' do
    @application.update!(submission_method: :paper)
    @user.update!(communication_preference: :email)
    secure_upload_url = 'https://example.test/secure_proof_form?token=abc'

    email = ApplicationNotificationsMailer.proof_rejected(
      @application,
      @proof_review,
      secure_upload_url: secure_upload_url
    )
    email.deliver_now

    assert_equal [@user.email], email.to
    assert_includes decoded_text_part(email), secure_upload_url
    assert_includes decoded_text_part(email), 'Secure corrected proof upload link'
  end

  test 'proof_rejected renders none_provided id reason as friendly text without seed row' do
    RejectionReason.where(code: 'none_provided', proof_type: 'id', locale: %w[en es]).delete_all
    proof_review = create(
      :proof_review,
      :rejected,
      application: @application,
      proof_type: :id,
      rejection_reason: 'none_provided',
      rejection_reason_code: nil
    )

    email = ApplicationNotificationsMailer.proof_rejected(@application, proof_review)
    email.deliver_now

    assert_includes email.body.to_s, 'No proof of identity was provided with the application.'
    assert_not_includes email.body.to_s, 'none_provided'
  end

  test 'proof_rejected preserves custom rejection text when it is not a known reason code' do
    custom_reason = 'The uploaded photo is too blurry to read.'
    proof_review = create(
      :proof_review,
      :rejected,
      application: @application,
      proof_type: :id,
      rejection_reason: custom_reason,
      rejection_reason_code: nil
    )

    email = ApplicationNotificationsMailer.proof_rejected(@application, proof_review)
    email.deliver_now

    assert_includes email.body.to_s, custom_reason
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
    assert_includes email.body.to_s, I18n.t(
      'application_notifications.proof_rejected.remaining_attempts_message',
      count: 6,
      locale: 'es',
      reapply_date: I18n.l(3.years.from_now.to_date, format: :long, locale: 'es')
    )
    assert_includes email.body.to_s, I18n.l(3.years.from_now.to_date, format: :long, locale: 'es')
    assert_includes email.body.to_s, 'CÓMO ENVIAR UN DOCUMENTO CORREGIDO'
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
    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.max_rejections_reached(@application)
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to

    expected_subject = 'Mock Application Archived - ID 7'
    assert_equal expected_subject, email.subject

    assert_not email.multipart?

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
    applications = [@application]

    # Only reviews older than three days enter the reminder.
    @application.stubs(:needs_review_since).returns(4.days.ago)

    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    emails = capture_emails do
      ApplicationNotificationsMailer.proof_needs_review_reminder(@admin, applications).deliver_now
    end

    assert_equal 1, emails.size
    email = emails.first

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@admin.email], email.to
    expected_subject = "Mock Reminder: #{applications.count} Apps Need Review"
    assert_equal expected_subject, email.subject

    assert_not email.multipart?

    assert_includes email.body.to_s, "Reminder for #{@admin.full_name}"
    assert_includes email.body.to_s, "#{applications.count} apps need review"
    assert_includes email.body.to_s, "ID: #{@application.id}"
  end

  test 'proof_needs_review_reminder uses English template for Spanish locale admin' do
    @admin.update!(locale: 'es')
    @application.stubs(:needs_review_since).returns(4.days.ago)

    email = ApplicationNotificationsMailer.proof_needs_review_reminder(@admin, [@application])
    email.deliver_now

    assert_equal [@admin.email], email.to
    assert_equal 'Mock Reminder: 1 Apps Need Review', email.subject
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

    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.account_created(constituent)
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [constituent.email], email.to

    expected_subject = "Mock Account Created for #{constituent.first_name}"
    assert_equal expected_subject, email.subject

    assert_includes decoded_text_part(email), "Welcome #{constituent.first_name}"
    assert_includes decoded_text_part(email), 'mat.program1@maryland.gov'
    assert_includes decoded_text_part(email), ProgramContact.website_url
    assert_not_includes decoded_text_part(email), temp_password
    assert_not_includes decoded_text_part(email), 'http://example.com/users/sign_in'
  end

  test 'security_key_recovery_approved includes account access link' do
    ApplicationNotificationsMailer.any_instance.unstub(:sign_in_url)
    original_default_url_options = Rails.application.config.action_mailer.default_url_options&.dup
    Rails.application.config.action_mailer.default_url_options = { host: 'test.example.com' }
    user = create(:constituent, first_name: 'Jane')
    recovery_request = create(:recovery_request, user: user, status: 'approved')
    notification = Notification.new(recipient: user, notifiable: recovery_request, action: 'security_key_recovery_approved')

    email = ApplicationNotificationsMailer.security_key_recovery_approved(recovery_request, notification)

    assert_emails 1 do
      email.deliver_now
    end
    assert_equal [user.email], email.to
    assert_includes decoded_text_part(email), 'Recovery approved for Jane'
    assert_includes decoded_text_part(email), 'http://test.example.com/sign_in'
  ensure
    Rails.application.config.action_mailer.default_url_options = original_default_url_options
  end

  test 'security_key_recovery_approved fails fast for unsafe production canonical host' do
    ApplicationNotificationsMailer.any_instance.unstub(:sign_in_url)
    original_default_url_options = Rails.application.config.action_mailer.default_url_options&.dup
    Rails.application.config.action_mailer.default_url_options = { host: 'example.com', protocol: 'https' }
    Rails.env.stubs(:production?).returns(true)
    user = create(:constituent, first_name: 'Jane')
    recovery_request = create(:recovery_request, user: user, status: 'approved')
    notification = Notification.new(recipient: user, notifiable: recovery_request, action: 'security_key_recovery_approved')

    error = assert_raises(ArgumentError) do
      ApplicationNotificationsMailer.security_key_recovery_approved(recovery_request, notification).deliver_now
    end

    assert_equal 'Canonical public URL host is not configured', error.message
  ensure
    Rails.application.config.action_mailer.default_url_options = original_default_url_options
  end

  test 'security_key_recovery_approved uses recipient locale for Spanish locale staff recipient when available' do
    spanish_template = mock_template('Recuperacion de llave de seguridad aprobada',
                                     "Recuperacion aprobada para %<user_first_name>s.\n\n" \
                                     "Iniciar sesion:\n%<sign_in_url>s")
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_security_key_recovery_approved',
      format: :text,
      locale: 'es'
    ).returns(spanish_template)
    user = create(:admin, first_name: 'Staff', locale: 'es')
    recovery_request = create(:recovery_request, user: user, status: 'approved')
    notification = Notification.new(recipient: user, notifiable: recovery_request, action: 'security_key_recovery_approved')

    email = ApplicationNotificationsMailer.security_key_recovery_approved(recovery_request, notification)
    email.deliver_now

    assert_equal [user.email], email.to
    assert_equal 'Recuperacion de llave de seguridad aprobada', email.subject
    assert_includes decoded_text_part(email), 'Recuperacion aprobada para Staff'
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
      communication_preference: 'letter',
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    )
    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.stubs(:new).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.account_created(constituent)
    assert_no_emails do
      delivery.deliver_now
    end
  end

  def setup_income_threshold_test_data
    @constituent_params = {
      first_name: 'John',
      last_name: 'Doe',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      communication_preference: 'letter'
    }

    @notification_params = {
      household_size: 2,
      annual_income: 100_000,
      communication_preference: 'email', # Overrides the constituent's delivery preference.
      additional_notes: 'Income exceeds threshold'
    }

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

    mock_income_exceeded_text = mock_template("Mock Income Threshold Exceeded for #{@constituent_params[:first_name]}",
                                              "Text Body: #{@constituent_params[:first_name]}, your income exceeds the " \
                                              "threshold for household size #{@notification_params[:household_size]}. " \
                                              "#{@notification_params[:additional_notes]}")

    EmailTemplate.stubs(:find_by!).with(name: 'application_notifications_income_threshold_exceeded',
                                        format: :text, locale: 'en').returns(mock_income_exceeded_text)

    ActionMailer::Base.default from: 'no_reply@mdmat.org'

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.income_threshold_exceeded(@constituent_params, @notification_params)
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@constituent_params[:email]], email.to

    expected_subject = "Mock Income Threshold Exceeded for #{@constituent_params[:first_name]}"
    assert_equal expected_subject, email.subject

    assert_not email.multipart?

    assert_includes email.body.to_s, "#{@constituent_params[:first_name]}, your income"
    assert_includes email.body.to_s, "household size #{@notification_params[:household_size]}"
    assert_includes email.body.to_s, @notification_params[:additional_notes]
  end

  test 'registration_confirmation' do
    user = Constituent.create!(
      first_name: 'Jane',
      last_name: 'Smith',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      password: 'password',
      password_confirmation: 'password',
      hearing_disability: true
    )

    active_vendors = []
    Vendor.stubs(:active).returns(Vendor.none)
    Vendor.none.stubs(:order).returns(active_vendors)

    mock_template(
      'Mock Welcome Jane!',
      "Text Body: Welcome, Jane!\n\n" \
      "Dashboard link:\nhttp://example.com/dashboard\n\n" \
      "New application link:\nhttp://example.com/applications/new\n\n" \
      'No authorized vendors found at this time.'
    )

    email = ApplicationNotificationsMailer.registration_confirmation(user)

    assert_emails 1 do
      email.deliver_now
    end

    assert_equal ['no_reply@mdmat.org'], email.from, 'Email should be from no_reply@mdmat.org'
    assert_equal [user.email], email.to, 'Email should be sent to the registered user'
    assert_equal 'Mock Welcome Jane!', email.subject, 'Email subject should match mock'

    text_content = decoded_text_part(email)
    assert_match 'Welcome, Jane!', text_content
    assert_match "Dashboard link:\nhttp://example.com/dashboard", text_content
    assert_match "New application link:\nhttp://example.com/applications/new", text_content
    assert_match 'No authorized vendors found at this time.', text_content
  end

  test 'registration_confirmation generates letter when preference is letter' do
    user = Constituent.create!(
      first_name: 'Jane',
      last_name: 'Smith',
      email: "unique-#{SecureRandom.hex(4)}@example.com",
      phone: "555-555-#{SecureRandom.rand(1000..9999)}",
      password: 'password',
      password_confirmation: 'password',
      hearing_disability: true,
      communication_preference: 'letter',
      physical_address_1: '123 Main St',
      city: 'Baltimore',
      state: 'MD',
      zip_code: '21201'
    )

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

  test 'with_mailer_error_handling redacts secure URLs from logs' do
    mailer = ApplicationNotificationsMailer.new
    production_env = ActiveSupport::StringInquirer.new('production')
    original_logger = Rails.logger
    log_output = StringIO.new
    raw_url = 'https://example.test/secure_provider_info_form?token=secret-token'

    Rails.stubs(:env).returns(production_env)
    Rails.logger = ActiveSupport::Logger.new(log_output)

    mailer.send(:with_mailer_error_handling, 'provider_info_requested', raise_in_test_only: true) do
      raise StandardError, "render failed for #{raw_url}"
    end

    log_message = log_output.string
    assert_includes log_message, '[REDACTED_URL]'
    assert_not_includes log_message, raw_url
    assert_not_includes log_message, 'secret-token'
  ensure
    Rails.logger = original_logger
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

  test 'proof_requested email uses the delivery owner locale and snapshot address' do
    @user.update!(communication_preference: 'letter')
    owner = create(:constituent, locale: 'es')
    proof_template = mock_template('Solicitud de documento', 'Texto de solicitud')
    EmailTemplate.expects(:find_by!).with(
      name: 'application_notifications_proof_requested', format: :text, locale: 'es'
    ).returns(proof_template)
    snapshot_email = "snapshot.#{SecureRandom.hex(3)}@example.com"
    form = create(:secure_request_form,
                  application: @application,
                  recipient: @user,
                  delivery_owner: owner,
                  delivery_source: 'managing_guardian',
                  kind: :id_proof_resubmission,
                  recipient_channel: :email,
                  recipient_email: snapshot_email)

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.proof_requested(
        @application,
        :id,
        secure_upload_url: 'https://example.test/secure_proof_form?token=abc',
        recipient: @user,
        secure_request_form: form,
        letter_recipient: @user
      )
      email.deliver_now
    end

    assert_equal [snapshot_email], email.to
  end

  test 'proof_rejected with an email secure request form sends to the snapshot address despite letter preference' do
    @user.update!(communication_preference: 'letter')
    snapshot_email = "snapshot.#{SecureRandom.hex(3)}@example.com"
    form = create(:secure_request_form,
                  application: @application,
                  recipient: @user,
                  kind: :income_proof_resubmission,
                  recipient_channel: :email,
                  recipient_email: snapshot_email)

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.proof_rejected(
        @application,
        @proof_review,
        secure_upload_url: 'https://example.test/secure_proof_form?token=abc',
        recipient: @user,
        secure_request_form: form,
        letter_recipient: @user
      )
      email.deliver_now
    end

    assert_equal [snapshot_email], email.to
  end

  test 'proof_requested with a letter secure request form prints to the resolver-selected address owner' do
    guardian = create(:constituent)
    dependent = create(:constituent, communication_preference: 'email')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :id_proof_resubmission,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with(
      has_entries(recipient: guardian)
    ).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.proof_requested(
      @application,
      :id,
      secure_upload_url: 'https://example.test/secure_proof_form?token=abc',
      recipient: dependent,
      secure_request_form: form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }
  end

  test 'proof_rejected with a letter secure request form prints to the resolver-selected address owner' do
    guardian = create(:constituent)
    dependent = create(:constituent, communication_preference: 'email')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :income_proof_resubmission,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with(
      has_entries(recipient: guardian)
    ).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.proof_rejected(
      @application,
      @proof_review,
      recipient: dependent,
      secure_request_form: form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }
  end

  test 'provider_info_requested letter prints to the resolver-selected address owner' do
    provider_info_template = mock_template('Mock Provider Info Requested',
                                           'Text Body: provider info requested for %<user_first_name>s.')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_provider_info_requested', format: :text, locale: 'en'
    ).returns(provider_info_template)
    guardian = create(:constituent)
    dependent = create(:constituent, communication_preference: 'email')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :provider_info_request,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with(
      has_entries(recipient: guardian)
    ).returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.provider_info_requested(
      @application,
      form,
      secure_url: 'https://example.test/secure_provider_info_form?token=abc',
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }
  end

  test 'provider_info_requested email uses the delivery owner locale and encrypted snapshot address' do
    provider_info_template = mock_template('Mock Provider Info Requested',
                                           'Text Body: provider info requested for %<user_first_name>s.')
    owner = create(:constituent, locale: 'es')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_provider_info_requested', format: :text, locale: 'es'
    ).returns(provider_info_template)
    snapshot_email = "snapshot.#{SecureRandom.hex(3)}@example.com"
    form = create(:secure_request_form,
                  application: @application,
                  recipient: @user,
                  delivery_owner: owner,
                  delivery_source: 'managing_guardian',
                  kind: :provider_info_request,
                  recipient_channel: :email,
                  recipient_email: snapshot_email)

    email = nil
    assert_emails 1 do
      email = ApplicationNotificationsMailer.provider_info_requested(
        @application,
        form,
        secure_url: 'https://example.test/secure_provider_info_form?token=abc'
      )
      email.deliver_now
    end

    assert_equal [snapshot_email], email.to
  end

  test 'provider_info_requested letter builds variables in the address owner locale not the recipient locale' do
    provider_info_template = mock_template('Mock Provider Info Requested',
                                           'Text Body: %<provider_info_instructions>s')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_provider_info_requested', format: :text, locale: 'en'
    ).returns(provider_info_template)
    guardian = create(:constituent, locale: 'en')
    dependent = create(:constituent, locale: 'es', communication_preference: 'letter')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :provider_info_request,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with do |*args|
      opts = args.last
      opts[:recipient] == guardian &&
        opts[:variables][:provider_info_instructions].include?('Please contact our team by phone')
    end.returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.provider_info_requested(
      @application,
      form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }
  end

  test 'provider_info_requested letter uses the spanish address owner locale for a spanish guardian' do
    provider_info_template_es = mock_template('Mock Solicitud de Información',
                                              'Texto: %<provider_info_instructions>s')
    EmailTemplate.stubs(:find_by!).with(
      name: 'application_notifications_provider_info_requested', format: :text, locale: 'es'
    ).returns(provider_info_template_es)
    guardian = create(:constituent, locale: 'es')
    dependent = create(:constituent, locale: 'en', communication_preference: 'letter')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :provider_info_request,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with do |*args|
      opts = args.last
      opts[:recipient] == guardian &&
        opts[:variables][:provider_info_instructions].include?('Comuníquese con nuestro equipo')
    end.returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.provider_info_requested(
      @application,
      form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }
  end

  test 'proof_requested letter builds variables in the address owner locale' do
    guardian = create(:constituent, locale: 'en')
    dependent = create(:constituent, locale: 'es', communication_preference: 'letter')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :id_proof_resubmission,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    pdf_service_mock = mock('pdf_service')
    pdf_service_mock.expects(:queue_for_printing).once
    Letters::TextTemplateToPdfService.expects(:new).with do |*args|
      opts = args.last
      opts[:recipient] == guardian &&
        opts[:variables][:default_options_text].include?('HOW TO SUBMIT THIS DOCUMENT')
    end.returns(pdf_service_mock)

    delivery = ApplicationNotificationsMailer.proof_requested(
      @application,
      :id,
      recipient: dependent,
      secure_request_form: form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }
  end

  test 'provider_info_requested letter PDF output is entirely in the spanish address owner locale' do
    # Template markers and translated instructions independently verify the locale through the real PDF service.
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.where(name: 'application_notifications_provider_info_requested', format: :text).destroy_all
    %w[en es].each do |locale|
      create(:email_template,
             name: 'application_notifications_provider_info_requested',
             format: :text,
             locale: locale,
             subject: "LETTER SUBJECT #{locale.upcase} MARKER",
             body: "LETTER BODY #{locale.upcase} MARKER\n\n%<provider_info_instructions>s",
             variables: { 'required' => %w[provider_info_instructions], 'optional' => [] })
    end
    guardian = create(:constituent, locale: 'es')
    dependent = create(:constituent, locale: 'en', communication_preference: 'letter')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :provider_info_request,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    delivery = ApplicationNotificationsMailer.provider_info_requested(
      @application,
      form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }

    item = PrintQueueItem.order(:created_at).last
    assert_equal guardian.id, item.constituent_id
    assert_equal 'provider_info_requested', item.letter_type

    pdf_text = inflated_pdf_text(item.pdf_letter.download)
    assert_includes pdf_text, 'LETTER BODY ES MARKER'
    # ASCII-safe fragment of the Spanish letter instructions (accents are WinAnsi-encoded).
    assert_includes pdf_text, 'con nuestro equipo por'
    assert_not_includes pdf_text, 'LETTER BODY EN MARKER'
    assert_not_includes pdf_text, 'Please contact our team'
  end

  test 'spanish provider info letter renders a reviewable PDF artifact' do
    # Text assertions cannot verify layout or glyphs. This PDF supports visual review.
    EmailTemplate.unstub(:find_by!)
    EmailTemplate.where(name: 'application_notifications_provider_info_requested', format: :text).destroy_all
    %w[en es].each do |locale|
      create(:email_template,
             name: 'application_notifications_provider_info_requested',
             format: :text,
             locale: locale,
             subject: "LETTER SUBJECT #{locale.upcase} MARKER",
             body: "LETTER BODY #{locale.upcase} MARKER\n\n%<provider_info_instructions>s",
             variables: { 'required' => %w[provider_info_instructions], 'optional' => [] })
    end
    guardian = create(:constituent, locale: 'es', physical_address_1: '9 Guardian Way')
    dependent = create(:constituent, locale: 'en', communication_preference: 'letter')
    form = create(:secure_request_form,
                  application: @application,
                  recipient: dependent,
                  delivery_owner: guardian,
                  delivery_source: 'managing_guardian',
                  kind: :provider_info_request,
                  recipient_channel: :letter,
                  recipient_email: nil,
                  recipient_phone: nil)

    delivery = ApplicationNotificationsMailer.provider_info_requested(
      @application,
      form,
      letter_recipient: guardian
    )
    assert_no_emails { delivery.deliver_now }

    item = PrintQueueItem.order(:created_at).last
    pdf_path = Rails.root.join('tmp/capybara/1_secure-request-letter-spanish.pdf')
    pdf_path.dirname.mkpath
    File.binwrite(pdf_path, item.pdf_letter.download)
    pdf_path.sub_ext('.json').write(
      JSON.pretty_generate(
        generated_at: Time.current.iso8601,
        test_class: self.class.name,
        test_name: name,
        label: 'secure-request-letter-spanish',
        artifact_usable_for_llm_qa: true,
        unusable_reasons: [],
        pdf_path: pdf_path.to_s
      )
    )

    assert_path_exists pdf_path
    assert_operator pdf_path.size, :>, 1_000
  end

  # Prawn uses FlateDecode and hex glyph runs with kerning splits ("[<4c4554...> 90 <59...>] TJ").
  # This extracts text without a PDF parser.
  def inflated_pdf_text(pdf_binary)
    content = pdf_binary.scan(/stream\r?\n(.*?)endstream/m).flatten.map do |stream|
      Zlib::Inflate.inflate(stream)
    rescue Zlib::Error
      stream.dup
    end.join
    content.scan(/<([0-9a-fA-F]+)>/).flatten.map { |hex| [hex].pack('H*') }.join.force_encoding('BINARY')
  end
end
