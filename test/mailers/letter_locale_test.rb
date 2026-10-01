# frozen_string_literal: true

require 'test_helper'

class LetterLocaleTest < ActiveSupport::TestCase
  test 'registration letter uses message locale after choosing a different postal owner' do
    name = 'application_notifications_registration_confirmation'
    %w[en es].each do |locale|
      EmailTemplate.find_by!(name: name, format: :text, locale: locale).update!(subject: "LANGUAGE_#{locale.upcase}")
    end
    guardian = create(:constituent, locale: 'en', communication_preference: 'letter')
    dependent = create(:constituent, locale: 'es', dependent_email: 'dependent.locale@example.test')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
    assert_equal 'es', dependent.effective_locale

    capture_letter { ApplicationNotificationsMailer.registration_confirmation(dependent).message }

    assert_equal guardian.id, @letter.recipient.id
    assert_equal 'es', @letter.template.locale
    assert_includes @letter.variables[:header_text], 'LANGUAGE_ES'
    subject, body = @letter.send(:rendered_template)
    assert_equal 'LANGUAGE_ES', subject
    assert_includes body, 'LANGUAGE_ES'
    pdf = mock('pdf')
    pdf.expects(:text).with("Estimado/a #{guardian.first_name},")
    pdf.expects(:move_down).with(10)
    @letter.send(:add_salutation, pdf)
  end

  test 'secure letter uses the forms delivery owner rather than the default guardian locale' do
    guardian = create(:constituent, locale: 'en')
    owner = create(:constituent, locale: 'es')
    dependent = create(:constituent, locale: 'en', dependent_email: guardian.email)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: dependent)
    application = create(:application, user: dependent, managing_guardian: guardian)
    form = create(:secure_request_form, application: application, recipient: dependent,
                                        delivery_owner: owner, recipient_channel: :letter, kind: :provider_info_request)
    assert_equal :es, form.delivery_locale

    capture_letter { ApplicationNotificationsMailer.provider_info_requested(application, form, letter_recipient: owner).message }

    assert_equal owner.id, @letter.recipient.id
    assert_equal 'es', @letter.template.locale
    assert_equal 'es', @letter.send(:resolved_locale)
  end

  private

  def capture_letter
    constructor = Letters::TextTemplateToPdfService.method(:new)
    queue = mock('queue')
    queue.expects(:queue_for_printing).returns(true)
    Letters::TextTemplateToPdfService.expects(:new).with do |**args|
      @letter = constructor.call(**args)
      true
    end.returns(queue)
    yield
  end
end
