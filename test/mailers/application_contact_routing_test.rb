# frozen_string_literal: true

require 'test_helper'

class ApplicationContactRoutingTest < ActionMailer::TestCase
  setup do
    EmailTemplate.where(name: 'application_notifications_application_submitted', format: :text).destroy_all
    %w[application_notifications_application_submitted application_notifications_application_submitted_es].each do |name|
      load Rails.root.join("db/seeds/email_templates/#{name}.rb")
    end
  end

  test 'ordinary application email resolves the managing guardian rather than the first relationship' do
    application, guardian, first_guardian = dependent_application

    mail = ApplicationNotificationsMailer.application_submitted(application).deliver_now

    assert_equal [guardian.email], mail.to
    assert_equal EmailTemplate.find_by!(name: 'application_notifications_application_submitted', format: :text, locale: 'es').render_subject(
      user_first_name: application.user.first_name, application_id: application.id
    ), mail.subject
    assert_not_includes Array(mail.to), first_guardian.email
  end

  test 'ordinary application letter follows managing guardian preference despite applicant owned email' do
    application, guardian = dependent_application(preference: 'letter', own_email: true)
    Letters::TextTemplateToPdfService.expects(:new).with do |**arguments|
      arguments[:recipient] == guardian && arguments[:locale] == 'es'
    end.returns(mock(queue_for_printing: true))

    assert_no_emails { ApplicationNotificationsMailer.application_submitted(application).deliver_now }
  end

  test 'ordinary email uses the applicant owned email language when the guardian selects email' do
    application, = dependent_application(own_email: true)

    mail = ApplicationNotificationsMailer.application_submitted(application).deliver_now

    assert_equal [application.user.email], mail.to
    assert_equal EmailTemplate.find_by!(name: 'application_notifications_application_submitted', format: :text, locale: 'en').render_subject(
      user_first_name: application.user.first_name, application_id: application.id
    ), mail.subject
  end

  test 'ordinary email retains applicant preference and language after the managing guardian is removed' do
    application, manager, remaining_guardian = dependent_application(own_email: true)
    remaining_guardian.update!(locale: 'es')
    GuardianRelationship.find_by!(guardian_user: manager, dependent_user: application.user).destroy!
    application.update!(managing_guardian: nil)
    application.reload
    assert_nil application.managing_guardian
    Letters::TextTemplateToPdfService.expects(:new).never

    mail = ApplicationNotificationsMailer.application_submitted(application).deliver_now

    assert_equal [application.user.email], mail.to
    assert_equal EmailTemplate.find_by!(name: 'application_notifications_application_submitted', format: :text, locale: 'en').render_subject(
      user_first_name: application.user.first_name, application_id: application.id
    ), mail.subject
  end

  test 'application context does not substitute contacts for another recipient or an explicit own email request' do
    application, guardian = dependent_application
    mailer = ApplicationMailer.new
    mailer.instance_variable_set(:@delivery_subject, application)

    assert_equal guardian.email, mailer.send(:recipient_email_for, guardian)
    assert_equal application.user.email, mailer.send(:recipient_email_for, application.user, own_email: true)
  end

  test 'positional training mail resolves the application manager contacts and locale' do
    template_name = 'training_session_notifications_training_scheduled'
    EmailTemplate.where(name: template_name, format: :text).destroy_all
    [template_name, "#{template_name}_es"].each do |name|
      load Rails.root.join("db/seeds/email_templates/#{name}.rb")
    end
    application, manager, first_guardian = dependent_application
    training_session = create(:training_session, :scheduled, application: application)

    mail = TrainingSessionNotificationsMailer.training_scheduled(training_session).deliver_now

    assert_equal [manager.email], mail.to
    assert_equal EmailTemplate.find_by!(name: template_name, format: :text, locale: 'es').render_subject, mail.subject
    assert_includes mail.body.decoded, "Hola #{application.user.full_name}"
    assert_not_includes Array(mail.to), first_guardian.email
    assert_not_includes Array(mail.to), application.user.email
  end

  private

  def dependent_application(preference: 'email', own_email: false)
    first_guardian = create(:constituent, locale: 'en', communication_preference: 'letter')
    guardian = create(:constituent, locale: 'es', communication_preference: preference)
    attributes = { locale: 'en', communication_preference: 'email' }
    attributes[:email] = "dependent-#{SecureRandom.uuid}@system.matvulcan.local" unless own_email
    applicant = create(:constituent, **attributes)
    applicant.update!(dependent_email: applicant.email) if own_email
    create(:guardian_relationship, guardian_user: first_guardian, dependent_user: applicant)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)
    application = create(:application, user: applicant, managing_guardian: guardian)
    [application, guardian, first_guardian]
  end
end
