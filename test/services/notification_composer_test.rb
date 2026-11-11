# frozen_string_literal: true

require 'test_helper'

class NotificationComposerTest < ActiveSupport::TestCase
  setup do
    @admin = create(:admin, first_name: 'Admin', last_name: 'User')
    @constituent = create(:constituent, first_name: 'John', last_name: 'Doe')
    @application = create(:application, user: @constituent)
  end

  teardown do
    Current.reset
  end

  test 'voucher expiration history is localized for the current viewer' do
    { en: 'Your voucher has expired.', es: 'Su vale ha vencido.' }.each do |locale, expected|
      I18n.with_locale(locale) do
        assert_equal expected, NotificationComposer.generate('voucher_expired', nil)
      end
    end
  end

  test 'proof notification language follows the viewer while preserving its constituent destination' do
    notification = build(
      :notification, action: 'proof_rejected', notifiable: @application, actor: @admin,
                     metadata: { proof_type: 'income', rejection_reason: 'Unreadable document' }
    )
    { 'en' => 'Income proof rejected for', 'es' => 'Comprobante de ingresos rechazado para' }.each do |locale, expected|
      @constituent.update!(locale: locale)
      message = I18n.with_locale(locale == 'en' ? :es : :en) { notification.message(@constituent) }

      assert_includes message, expected
      fragment = Nokogiri::HTML.fragment(message)
      assert_equal 1, fragment.css('a').size
      assert_equal "/constituent_portal/applications/#{@application.id}", fragment.at_css('a')['href']
      assert_includes fragment.at_css('a').text, 'John Doe'
    end
  end

  test 'explicit request locale overrides the viewer language through the notification model' do
    @constituent.update!(locale: 'es')
    notification = build(
      :notification, action: 'proof_approved', notifiable: @application, actor: @admin,
                     metadata: { proof_type: 'residency' }
    )

    message = notification.message(@constituent, locale: :en)

    assert_includes message, 'Residency proof approved for'
    assert_includes Nokogiri::HTML.fragment(message).at_css('a').text, "Application ##{@application.id}"
    assert_not_includes message, 'Comprobante de residencia'
  end

  test 'notification language uses the viewer effective guardian locale rather than the stored locale' do
    guardian = create(:constituent, locale: 'es')
    create(:guardian_relationship, guardian_user: guardian, dependent_user: @constituent)
    @constituent.reload
    assert_equal 'en', @constituent.locale
    assert_equal :es, @constituent.effective_message_locale

    message = I18n.with_locale(:en) do
      NotificationComposer.generate('training_trainer_changed', nil, @admin, { trainer_name: 'Jane Trainer' }.stringify_keys,
                                    viewer: @constituent)
    end

    assert_equal 'Su capacitación ahora está a cargo de Jane Trainer. Las citas programadas no han cambiado.', message
  end

  test 'translated proof notification escapes names and reasons while retaining the generated link' do
    @constituent.first_name = '<script>alert(1)</script>'
    @constituent.locale = 'es'
    reason = '<img src=x onerror=alert(2)>'

    message = NotificationComposer.generate('proof_rejected', @application, @admin,
                                            { proof_type: 'id', rejection_reason: reason }, viewer: @constituent, locale: :es)
    fragment = Nokogiri::HTML.fragment(message)

    assert_predicate message, :html_safe?
    assert_empty fragment.css('script, img')
    assert_includes fragment.text, reason
    assert_includes fragment.at_css('a').text, '<script>alert(1)</script>'
    assert_equal "/constituent_portal/applications/#{@application.id}", fragment.at_css('a')['href']
    assert_match(/\AVer Solicitud/, fragment.at_css('a')['aria-label'])
  end

  test 'stored training notification without an actor uses its preloaded trainer in the viewer language' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    session = create(:training_session, :scheduled, application: @application, trainer: trainer)
    session.trainer
    @constituent.update!(locale: 'es')

    message = NotificationComposer.generate('training_scheduled', session, nil, {}, viewer: @constituent)

    assert_includes message, 'Jane Trainer programó la capacitación de John Doe'
    assert_equal "/constituent_portal/applications/#{@application.id}", Nokogiri::HTML.fragment(message).at_css('a')['href']
  end

  test 'generate message for proof_approved' do
    message = NotificationComposer.generate(
      'proof_approved',
      @application,
      @admin,
      { 'proof_type' => 'income' }
    )
    assert_includes message, 'Income proof approved for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
  end

  test 'generate message for proof_rejected with reason' do
    message = NotificationComposer.generate(
      'proof_rejected',
      @application,
      @admin,
      { 'proof_type' => 'residency', 'rejection_reason' => 'Illegible document' }
    )
    assert_includes message, 'Residency proof rejected for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_includes message, 'Illegible document'
  end

  test 'proof_rejected reads proof metadata from paper template variables' do
    message = NotificationComposer.generate(
      'proof_rejected',
      @application,
      @admin,
      {
        'template_variables' => {
          'proof_type_formatted' => 'income',
          'rejection_reason' => 'Missing award letter'
        }
      }
    )

    assert_includes message, 'Income proof rejected for'
    assert_includes message, 'Missing award letter'
  end

  test 'typed proof rejected actions use proof review wording' do
    message = NotificationComposer.generate(
      'income_proof_rejected',
      @application,
      @admin,
      { 'rejection_reason' => 'Expired document' }
    )

    assert_includes message, 'Income proof rejected for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_includes message, 'Expired document'
    assert_not_includes message, 'notification regarding'
  end

  test 'proof notification with proof review notifiable links to application' do
    proof_review = ProofReview.new(id: @application.id + 100, application: @application)

    message = NotificationComposer.generate(
      'proof_rejected',
      proof_review,
      @admin,
      { 'proof_type' => 'income', 'rejection_reason' => 'Illegible document' }
    )

    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_includes message, "/admin/applications/#{@application.id}"
    assert_not_includes message, "/admin/applications/#{proof_review.id}"
  end

  test 'trainer assignment uses the session assignee and trainer destination while retaining the administrator actor' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    session = create(:training_session, application: @application, trainer: trainer)
    message = NotificationComposer.generate('trainer_assigned', session, @admin, {}, viewer: trainer)

    assert_includes message, 'Jane Trainer assigned to'
    assert_includes message, 'John Doe'
    assert_includes message, "/trainers/training_sessions/#{session.id}"
    assert_not_includes message, 'Admin User assigned'
    assert_not_includes message, '/admin/applications/'
  end

  test 'a transfer tells the new trainer which training moved and tells the constituent who has it now' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    session = create(:training_session, application: @application, trainer: trainer)

    to_trainer = NotificationComposer.generate('trainer_reassigned', session, @admin, {}, viewer: trainer)
    to_constituent = NotificationComposer.generate('training_trainer_changed', session, @admin, { 'trainer_name' => 'Jane Trainer' })

    assert_includes to_trainer, 'training for John Doe'
    assert_includes to_trainer, "/trainers/training_sessions/#{session.id}"
    assert_includes to_trainer, 'was transferred to you.'
    assert_includes to_constituent, 'Your training is now with Jane Trainer.'
  end

  test 'generate message for training_requested' do
    message = NotificationComposer.generate(
      'training_requested',
      @application,
      @constituent
    )
    assert message.include?('John Doe requested training for')
    assert message.include?(@application.id.to_s)
  end

  test 'generate messages for training session lifecycle notifications' do
    trainer = create(:trainer, first_name: 'Jane', last_name: 'Trainer')
    training_session = create(:training_session, :scheduled, application: @application, trainer: trainer)

    {
      'training_scheduled' => 'scheduled training',
      'training_rescheduled' => 'rescheduled training',
      'training_cancelled' => 'cancelled training',
      'training_completed' => 'completed training'
    }.each do |action, verb_phrase|
      message = NotificationComposer.generate(
        action,
        training_session,
        trainer,
        { 'application_id' => @application.id }
      )

      assert message.include?("Jane Trainer #{verb_phrase} for John Doe on")
      assert message.include?(@application.id.to_s)
    end
  end

  test 'disability certification request messages end with periods' do
    message = NotificationComposer.generate(
      'disability_certification_requested',
      @application,
      @admin
    )

    assert_includes message, 'Disability certification requested for'
    assert_match(%r{</a>\.$}, message)
  end

  test 'cert upload request messages end with periods' do
    message = NotificationComposer.generate(
      'cert_upload_requested',
      @application,
      @admin
    )

    assert_includes message, 'Secure disability certification upload requested for'
    assert_match(%r{</a>\.$}, message)
  end

  test 'generate message for disability_certification_rejected with rejection_reason' do
    message = NotificationComposer.generate(
      'disability_certification_rejected',
      @application,
      @admin,
      { 'rejection_reason' => 'Provider license missing' }
    )

    assert_includes message, 'Disability certification rejected for'
    assert_includes message, 'Provider license missing'
  end

  test 'generate message for proof_resubmission_requested' do
    message = NotificationComposer.generate(
      'proof_resubmission_requested',
      @application,
      @admin,
      {
        'proof_type' => 'id',
        'proof_request_display_mode' => 'rejected',
        'rejection_reason' => 'Too blurry'
      }
    )

    assert_includes message, 'ID proof rejected for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_includes message, "/admin/applications/#{@application.id}"
    assert_includes message, 'Too blurry'
    assert_not_includes message, 'Secure'
    assert_not_includes message, 'upload requested'
  end

  test 'proof_resubmission_requested uses requested snapshot despite stale rejection review' do
    Current.paper_context = true
    create(:proof_review,
           :rejected,
           application: @application,
           admin: @admin,
           proof_type: :id,
           rejection_reason: 'Old blurry document')
    Current.paper_context = false

    @application.update!(id_proof_status: :not_reviewed)

    message = NotificationComposer.generate(
      'proof_resubmission_requested',
      @application,
      @admin,
      { 'proof_type' => 'id', 'proof_request_display_mode' => 'requested' }
    )

    assert_includes message, 'ID proof requested for'
    assert_not_includes message, 'rejected'
    assert_not_includes message, 'Old blurry document'
  end

  test 'proof rejection fallback agrees for loaded and queried decisions using decision chronology' do
    create(:proof_review, :rejected, application: @application, proof_type: :id,
                                     rejection_reason: 'Earlier decision', created_at: 1.day.ago, reviewed_at: 3.days.ago)
    create(:proof_review, :rejected, application: @application, proof_type: :id,
                                     rejection_reason: 'Latest decision', created_at: 4.days.ago, reviewed_at: 1.hour.ago)

    [false, true].each do |preload|
      @application.association(:proof_reviews).reset
      @application.proof_reviews.load if preload
      message = NotificationComposer.generate('proof_resubmission_requested', @application, @admin,
                                              { 'proof_type' => 'id', 'proof_request_display_mode' => 'rejected' })

      assert_includes message, 'Latest decision'
      assert_not_includes message, 'Earlier decision'
    end
  end

  test 'proof_resubmission_requested falls back when no rejected review exists' do
    message = NotificationComposer.generate(
      'proof_resubmission_requested',
      @application,
      @admin,
      { 'proof_type' => 'income' }
    )

    assert_includes message, 'Income proof requested for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_not_includes message, 'rejected'
    assert_not_includes message, 'Secure'
  end

  test 'proof_resubmission_requested keeps rejected snapshot after application status changes' do
    @application.update!(income_proof_status: :not_reviewed)
    message = NotificationComposer.generate(
      'proof_resubmission_requested',
      @application,
      @admin,
      {
        'proof_type' => 'income',
        'proof_request_display_mode' => 'rejected',
        'rejection_reason' => 'Missing details'
      }
    )

    assert_includes message, 'Income proof rejected for'
    assert_includes message, 'Missing details'
  end

  test 'generate message for proof attached notifications' do
    message = NotificationComposer.generate(
      'id_proof_attached',
      @application,
      @constituent
    )

    assert_includes message, 'ID proof attached for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_includes message, "/admin/applications/#{@application.id}"
  end

  test 'generate default message for unknown action' do
    message = NotificationComposer.generate(
      'some_new_action',
      @application,
      @admin
    )
    assert_includes message, 'Some new action notification regarding'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_includes message, "/admin/applications/#{@application.id}"
  end

  test 'generate default message avoids namespaced Ruby class names' do
    vendor = build_stubbed(:vendor)

    message = NotificationComposer.generate(
      'vendor_max_w9_rejections_warning',
      vendor,
      @admin
    )

    assert_includes message, 'Vendor max w9 rejections warning notification regarding Vendor'
    assert_not_includes message, 'Users::Vendor'
  end

  test 'generate message for security key recovery requested' do
    recovery_request = build_stubbed(:recovery_request, user: @constituent)

    message = NotificationComposer.generate(
      'security_key_recovery_requested',
      recovery_request,
      @constituent
    )

    assert_equal 'Security key recovery requested for John Doe.', message
  end

  test 'legacy review_requested notification uses staff follow-up wording' do
    message = NotificationComposer.generate(
      'review_requested',
      @application,
      @constituent
    )

    assert_includes message, 'Staff follow-up requested for'
    assert_includes message, "Application ##{@application.id} (John Doe)"
    assert_not_includes message, 'Review requested'
  end

  test 'application_reference returns HTML link when notifiable has id' do
    composer = NotificationComposer.new('test', @application, @admin, {})
    result = composer.send(:application_reference)
    assert result.include?(@application.id.to_s)
    assert result.include?("Application ##{@application.id} (John Doe)")
    assert result.include?('<a')
    assert result.include?("aria-label=\"View Application ##{@application.id} (John Doe)\"")
    assert result.include?('text-primary-600')
    assert result.include?('</a>')
  end

  test 'application_reference uses constituent portal path for non-admin viewers' do
    composer = NotificationComposer.new('test', @application, @admin, {}, viewer: @constituent)

    assert_includes composer.send(:application_reference), "/constituent_portal/applications/#{@application.id}"
  end

  test 'application_reference links the current trainer, including an evaluator granted training, to the training session' do
    granted = create(:evaluator)
    create(:role_capability, user: granted, capability: 'can_train')
    @application.update_columns(assigned_trainer_id: granted.id)
    session = create(:training_session, application: @application, trainer: granted)

    reference = NotificationComposer.new('test', @application, @admin, {}, viewer: granted).send(:application_reference)
    assert_includes reference, "/trainers/training_sessions/#{session.id}"

    @application.update_columns(assigned_trainer_id: @admin.id)
    admin_reference = NotificationComposer.new('test', @application, @admin, {}, viewer: @admin).send(:application_reference)
    assert_includes admin_reference, "/admin/applications/#{@application.id}"
  end

  test 'application label uses constituent full name fallback when user is missing' do
    composer = NotificationComposer.new('test', nil, @admin, {})

    assert_equal 'Application #123 (Unknown Constituent)', composer.send(:application_label, Application.new(id: 123))
  end

  test 'escapes metadata in safe notification messages' do
    message = NotificationComposer.generate(
      'proof_rejected',
      @application,
      @admin,
      { 'proof_type' => 'income', 'rejection_reason' => '<script>alert(1)</script>' }
    )

    assert_includes message, '&lt;script&gt;alert(1)&lt;/script&gt;'
    assert_not_includes message, '<script>alert(1)</script>'
  end

  test 'application_reference returns Application missing when notifiable is nil' do
    composer = NotificationComposer.new('test', nil, @admin, {})
    assert_equal 'Application missing', composer.send(:application_reference)
  end

  test 'application_reference returns Application missing when notifiable has no id' do
    composer = NotificationComposer.new('test', Application.new(id: nil), @admin, {})
    assert_equal 'Application missing', composer.send(:application_reference)
  end

  test 'handles nil notifiable object gracefully' do
    message = NotificationComposer.generate('proof_approved', nil, @admin)
    assert_equal 'Proof approved for application missing.', message
  end
end
