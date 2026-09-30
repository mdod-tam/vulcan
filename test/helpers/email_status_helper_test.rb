# frozen_string_literal: true

require 'test_helper'

class EmailStatusHelperTest < ActionView::TestCase
  test 'a notification without delivery evidence has no panel' do
    notification = create(:notification, delivery_status: nil)
    assert_empty delivery_visibility(notification)
  end

  test 'a queued notification retains its recorded status without a provider attempt' do
    notification = create(:notification, delivery_status: :queued)
    assert_includes delivery_visibility(notification), 'data-delivery-status="queued"'
  end

  test 'an attempted but unconfirmed send remains visible as unknown' do
    notification = create(:notification)
    notification.email_delivery_attempts.create!(correlation_id: SecureRandom.uuid, recipient_key: EmailDeliveryAttempt.recipient_key('a@example.test'),
                                                 destination: 'a@example.test', server_id: '23', mail_action: 'UserMailer#password_reset', attempted_at: Time.current)
    assert_includes delivery_visibility(notification), 'data-delivery-status="unknown"'
  end

  test 'a local send failure renders safe error text without transport diagnostics' do
    notification = create(:notification)
    notification.mark_delivery_failed!(StandardError.new('transport error https://example.test/upload?token=secret'))

    html = delivery_visibility(notification)

    assert_includes html, 'data-delivery-status="failed"'
    assert_includes html, I18n.t('delivery_visibility.descriptions.failed')
    assert_not_includes html, 'secret'
    assert_not_includes html, 'transport error'
  end

  test 'basic status excludes diagnostic markup and suppression reasons in both locales' do
    notification = create(:notification)
    notification.mark_delivery_suppressed!('all_disabled')

    { en: 'Not sent', es: 'No enviado' }.each do |locale, label|
      html = delivery_visibility(notification, locale: locale, diagnostics: false)
      fragment = Nokogiri::HTML.fragment(html)

      assert_equal label, fragment.at_css('[data-delivery-status="suppressed"] span').text
      assert_empty fragment.css('details, summary')
      assert_not_includes html, I18n.t('delivery_visibility.reasons.all_disabled', locale: locale)
      assert_not_includes html, 'translation missing'
    end
  end
end
