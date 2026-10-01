# frozen_string_literal: true

require 'test_helper'

class DeliveryStatusPresenterTest < ActiveSupport::TestCase
  test 'details controls identify their record and individual attempt in both locales' do
    notification = create(:notification, delivery_status: :queued)
    attempts = 2.times.map do
      notification.email_delivery_attempts.create!(correlation_id: SecureRandom.uuid, destination: 'private@example.test',
                                                   recipient_key: EmailDeliveryAttempt.recipient_key('private@example.test'),
                                                   server_id: '23', mail_action: 'UserMailer#password_reset', attempted_at: Time.current)
    end

    %i[en es].each do |locale|
      labels = attempts.map do |attempt|
        presenter = DeliveryStatusPresenter.new(notification, attempt: attempt, locale: locale)
        html = ApplicationController.render(partial: 'shared/delivery/status', locals: { presenter: presenter })
        summary = Nokogiri::HTML.fragment(html).at_css('summary')
        assert_equal I18n.t('delivery_visibility.details', locale: locale), summary.text.strip
        assert_includes summary['aria-label'], notification.id.to_s
        assert_includes summary['aria-label'], attempt.id.to_s
        assert_not_includes summary['aria-label'], 'private@example.test'
        assert_not_includes summary['aria-label'], 'translation missing'
        summary['aria-label']
      end
      assert_equal labels.size, labels.uniq.size
    end
  end

  test 'legacy provider and placeholder IDs cannot establish a sent or delivered state' do
    notification = create(:notification, message_id: 'backfilled-123', delivery_status: :delivered)
    presenter = DeliveryStatusPresenter.new(notification)
    assert_equal 'unknown', presenter.status
    assert_nil presenter.sent_at
    assert_includes presenter.description, 'not tracked'
  end

  test 'local suppression explains the exact control and keeps intended SMS channel' do
    notification = create(:notification, metadata: { 'requested_channel' => 'sms' })
    notification.mark_delivery_suppressed!('all_disabled', channel: :sms)
    presenter = DeliveryStatusPresenter.new(notification, locale: :es)
    assert_equal 'sms', presenter.channel
    assert_equal 'No enviado — desactivado', presenter.label
    assert_equal 'Todas las comunicaciones están desactivadas.', presenter.description
  end

  test 'batch-preloaded history renders without row queries and without diagnostics or false sent dates' do
    forms = create_list(:secure_request_form, 3)
    forms.each do |form|
      create(:notification, notifiable: form.application, metadata: { 'secure_request_form_id' => form.id })
      EmailDeliveryAttempt.create!(origin: form, application: form.application, recipient: form.recipient, delivery_owner: form.delivery_owner,
                                   correlation_id: SecureRandom.uuid, destination: 'secret-person@example.test',
                                   recipient_key: EmailDeliveryAttempt.recipient_key('secret-person@example.test'), server_id: 'default',
                                   mail_action: 'ApplicationNotificationsMailer#provider_info_requested', attempted_at: Time.current,
                                   bounced_at: Time.current, bounce_category: 'HardBounce')
    end
    EmailDelivery::Visibility.preload(forms)
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] || payload[:name] == 'SCHEMA' }
    html = nil
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      html = forms.map { |form| ApplicationController.render(partial: 'shared/delivery/status', locals: { presenter: DeliveryStatusPresenter.new(form, attempt: form.email_delivery_attempts.first) }) }.join
    end
    assert_empty queries
    assert_includes html, 'Bounced'
    assert_includes html, '<summary'
    assert_includes html, 's***@example.test'
    assert_not_includes html, 'secret-person'
    assert_not_includes html, 'Sent on'
  end

  test 'pending letter history uses a batch snapshot without per-row render queries' do
    context = EmailDelivery::Policy.capture(mail_action: 'Letters#medical_certification_form')
    forms = create_list(:secure_request_form, 3, recipient_channel: :letter)
    forms.each do |form|
      identity = PrintQueueItem.identity_for(recipient: form.recipient, application: form.application, secure_request_form: form)
      create(:print_queue_item, :pending, constituent: form.recipient, application: form.application, secure_request_form: form,
                                          delivery_context: context, delivery_identity: identity)
    end
    EmailDelivery::Visibility.preload(forms)
    queries = []
    subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] unless payload[:cached] || payload[:name] == 'SCHEMA' }
    html = nil
    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      html = forms.map { |form| ApplicationController.render(partial: 'shared/delivery/status', locals: { presenter: DeliveryStatusPresenter.new(form) }) }.join
    end
    assert_empty queries
    assert_includes html, 'Waiting to send'
    assert_not_includes html, 'Sent on'
  end

  test 'a replacement provider request resolves current attention without deleting old bounce facts' do
    application = create(:application, medical_certification_status: :requested)
    old_attempt = EmailDeliveryAttempt.create!(origin: application, application: application, correlation_id: SecureRandom.uuid,
                                               destination: 'old@example.test', recipient_key: EmailDeliveryAttempt.recipient_key('old@example.test'),
                                               server_id: 'default', mail_action: 'MedicalProviderMailer#request_certification',
                                               attempted_at: 2.days.ago, bounced_at: 1.day.ago)
    assert EmailDelivery::Visibility.application_attention([application]).key?(application.id)
    EmailDeliveryAttempt.create!(origin: application, application: application, correlation_id: SecureRandom.uuid,
                                 destination: 'new@example.test', recipient_key: EmailDeliveryAttempt.recipient_key('new@example.test'),
                                 server_id: 'default', mail_action: 'MedicalProviderMailer#request_certification',
                                 attempted_at: Time.current, accepted_at: Time.current)
    assert_empty EmailDelivery::Visibility.application_attention([application])
    assert old_attempt.reload.bounced_at
  end

  test 'guardian attention follows destination at send and actionable request' do
    guardian = create(:constituent)
    form = create(:secure_request_form, delivery_owner: guardian, recipient_email: guardian.email)
    form.application.update_columns(medical_provider_name: nil, medical_provider_email: nil)
    attempt = EmailDeliveryAttempt.create!(origin: form, application: form.application, recipient: form.recipient, delivery_owner: guardian,
                                           correlation_id: SecureRandom.uuid, destination: guardian.email,
                                           recipient_key: EmailDeliveryAttempt.recipient_key(guardian.email), server_id: 'default',
                                           mail_action: 'ApplicationNotificationsMailer#provider_info_requested', attempted_at: Time.current, bounced_at: Time.current)
    assert_equal [attempt.id], EmailDelivery::Visibility.contact_attention(guardian).map(&:id)
    guardian.update!(email: 'replacement@example.test')
    assert_empty EmailDelivery::Visibility.contact_attention(guardian)
    assert_equal [attempt.id], EmailDelivery::Visibility.application_attention([form.application]).fetch(form.application_id).map(&:id)
    form.update!(status: :submitted, submitted_at: Time.current)
    assert_empty EmailDelivery::Visibility.application_attention([form.application])
    assert attempt.reload.bounced_at
  end
end
