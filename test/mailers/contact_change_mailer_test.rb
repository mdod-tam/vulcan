# frozen_string_literal: true

require 'test_helper'

class ContactChangeMailerTest < ActionMailer::TestCase
  setup do
    Current.reset
    EmailDelivery::Current.reset
    ensure_system_audit_actor!
    load_seeded_email_templates('contact_change_verification', 'contact_change_notice')
    @user = create(:constituent, communication_preference: 'email')
    Current.user = @user
    @old_method = ApplicationMailer.delivery_method
    @previous_server_id = ENV.fetch('POSTMARK_SERVER_ID', nil)
  end

  teardown do
    ApplicationMailer.delivery_method = @old_method
    ENV['POSTMARK_SERVER_ID'] = @previous_server_id
    EmailDelivery::Current.reset
    Current.reset
  end

  %w[en es].each do |locale|
    test "#{locale} proof mail uses immutable recipients and query tokens with the original deadline" do
      freeze_time do
        change = create_change(locale: locale)
        deadline = change.expires_at
        travel 10.minutes
        rendered_at = Time.current
        %w[old_email new_email].each do |role|
          travel_to rendered_at
          mail = mailer(change, role).verification.message
          assert_equal [role == 'old_email' ? change.old_value : change.proposed_value], mail.to
          expected_subject = locale == 'es' ? 'Confirme el contacto de su cuenta' : 'Confirm your account contact'
          assert_equal expected_subject, mail.subject
          url = URI.parse(mail.body.to_s[%r{https?://\S+}])
          query = URI.decode_www_form(url.query).to_h
          token = query.fetch('token')
          assert_equal locale, query.fetch('locale')
          assert_not_includes url.path, token
          assert_equal change, ContactChangeRequest.find_for_proof(token, role)
          assert_nil ContactChangeRequest.find_for_proof(token, role == 'old_email' ? 'new_email' : 'old_email')
          payload = Base64.urlsafe_decode64(token.split('--').first)
          [change.old_value, change.proposed_value].each { |contact| assert_not_includes payload, contact }
          assert_equal deadline, change.reload.expires_at
          travel_to deadline + 1.second
          assert_nil ContactChangeRequest.find_for_proof(token, role)
        end
      end
    end

    test "#{locale} security notices retain captured old and new destinations after account edits" do
      change = create_change(locale: locale)
      old_destination = change.notification_email
      @user.update!(email: "later-owner-#{SecureRandom.hex(4)}@example.test")
      %w[old_notice old_completed new_completed].each do |role|
        mail = mailer(change, role).security_notice.message
        assert_equal [role == 'new_completed' ? change.proposed_value : old_destination], mail.to
        expected_subject = locale == 'es' ? 'Aviso de seguridad del contacto de su cuenta' : 'Account contact security notice'
        assert_equal expected_subject, mail.subject
        key = role == 'old_notice' ? 'mail_requested' : 'mail_completed'
        assert_includes mail.body.to_s, I18n.t("contact_changes.#{key}", locale: locale)
        assert_not_includes mail.body.to_s, @user.email
      end
    end
  end

  test 'a proof rendered before expiry is refused by the final delivery callback after expiry' do
    freeze_time do
      change = create_change
      delivery = mailer(change, 'new_email').verification
      assert delivery.message
      travel_to change.expires_at + 1.second
      assert_no_difference('ActionMailer::Base.deliveries.size') do
        assert_raises(ApplicationMailer::DeliverySkipped) { delivery.deliver_now }
      end
    end
  end

  test 'an expired delayed proof job never reaches mail transport' do
    change = create_change
    change.update!(expires_at: 1.minute.ago)
    EmailDelivery.expects(:deliver_now!).never
    ContactChangeDeliveryJob.perform_now(change.id, 'new_email')
    assert_equal 'pending', change.reload.delivery_states.fetch('new_email')
  end

  test 'accepted Postmark proof is submitted once even when a worker repeats its saved envelope' do
    transport = use_postmark
    response = stub(code: '200', body: { MessageID: 'contact-provider-accepted', SubmittedAt: Time.current.iso8601,
                                         ErrorCode: 0, Message: 'OK' }.to_json)
    transport.expects(:post).once.returns(response)
    change = create_change
    correlation = EmailDeliveryAttempt.correlation_for(change.delivery_contexts.fetch('new_email'))

    ContactChangeDeliveryJob.perform_now(change.id, 'new_email')
    assert_equal 'submitted', change.reload.delivery_states.fetch('new_email')
    attempt = EmailDeliveryAttempt.where(correlation_id: correlation).sole
    assert_equal 'contact-provider-accepted', attempt.provider_message_id
    assert attempt.accepted_at
    assert_equal change.proposed_value, attempt.destination
    assert_equal change, attempt.origin

    change.update!(delivery_states: change.delivery_states.merge('new_email' => 'queued'))
    2.times { ContactChangeDeliveryJob.perform_now(change.id, 'new_email') }
    assert_equal 'submitted', change.reload.delivery_states.fetch('new_email')
    assert_equal 1, EmailDeliveryAttempt.where(correlation_id: correlation).count
  end

  test 'an ambiguous Postmark timeout remains unknown and repeated jobs cannot send the envelope again' do
    transport = use_postmark
    transport.expects(:post).once.raises(Timeout::Error)
    change = create_change
    context = change.delivery_contexts.fetch('new_email')
    correlation = EmailDeliveryAttempt.correlation_for(context)

    assert_raises(Postmark::TimeoutError) { ContactChangeDeliveryJob.perform_now(change.id, 'new_email') }
    assert_equal 'error', change.reload.delivery_states.fetch('new_email')
    attempt = EmailDeliveryAttempt.where(correlation_id: correlation).sole
    assert_equal 'unknown', attempt.state
    assert_nil attempt.accepted_at
    assert_nil attempt.provider_message_id

    2.times { ContactChangeDeliveryJob.perform_now(change.id, 'new_email') }
    assert_equal 'unknown', change.reload.delivery_states.fetch('new_email')
    assert_equal context, change.delivery_contexts.fetch('new_email')
    assert_equal 1, EmailDeliveryAttempt.where(correlation_id: correlation).count
    assert_nil attempt.reload.accepted_at
  end

  %w[accepted unknown].each do |outcome|
    test "a concurrent worker claim after preflight retains the #{outcome} receipt without a second handoff" do
      change = create_change
      context = change.delivery_contexts.fetch('new_email')
      other_worker_claim = lambda do |_delivery, context:|
        EmailDeliveryAttempt.create!(correlation_id: EmailDeliveryAttempt.correlation_for(context),
                                     recipient_key: EmailDeliveryAttempt.recipient_key(change.proposed_value),
                                     destination: change.proposed_value, server_id: '23', origin: change,
                                     mail_action: context.fetch('mail_action'), attempted_at: Time.current, state: outcome,
                                     accepted_at: (Time.current if outcome == 'accepted'))
        raise EmailDelivery::NotAccepted, 'Email delivery was not accepted'
      end

      EmailDelivery.stub(:deliver_now!, other_worker_claim) do
        ContactChangeDeliveryJob.perform_now(change.id, 'new_email')
      end

      assert_equal(outcome == 'accepted' ? 'submitted' : 'unknown', change.reload.delivery_states.fetch('new_email'))
      assert_equal context, change.delivery_contexts.fetch('new_email')
      assert_equal 1, EmailDeliveryAttempt.where(correlation_id: EmailDeliveryAttempt.correlation_for(context)).count
    end
  end

  test 'a false delivery result without a nonretryable receipt still fails visibly' do
    change = create_change
    EmailDelivery.expects(:deliver_now!).raises(EmailDelivery::NotAccepted, 'Email delivery was not accepted')
    assert_raises(EmailDelivery::NotAccepted) { ContactChangeDeliveryJob.perform_now(change.id, 'new_email') }
    assert_equal 'error', change.reload.delivery_states.fetch('new_email')
    assert_empty change.email_delivery_attempts
  end

  test 'the shared sender reports a refused adapter handoff with the typed refusal' do
    delivery = stub(deliver_now: false)
    assert_raises(EmailDelivery::NotAccepted) { EmailDelivery.deliver_now!(delivery) }
  end

  private

  def create_change(locale: 'en')
    change = ContactChangeRequest.new(user: @user, kind: 'email', old_value: @user.email, notification_email: @user.email,
                                      proposed_value: "verified-#{SecureRandom.hex(5)}@example.test", locale: locale,
                                      security_version: @user.security_version, old_confirmation_required: true,
                                      expires_at: ContactChangeRequest::LIFETIME.from_now)
    change.prepare_requested_deliveries!
    change.save!
    change
  end

  def mailer(change, role)
    ContactChangeMailer.with(contact_change_request: change, role: role, user: change.user)
  end

  def use_postmark
    ENV['POSTMARK_SERVER_ID'] = '23'
    ApplicationMailer.delivery_method = :postmark
    transport = mock('offline contact Postmark HTTP transport')
    Postmark::HttpClient.any_instance.stubs(:build_http).returns(transport)
    transport
  end
end
