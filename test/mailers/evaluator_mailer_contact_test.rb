# frozen_string_literal: true

require 'test_helper'
require_relative '../../db/migrate/20261011120100_neutralize_evaluation_confirmation_outcome_copy'

class EvaluatorMailerContactTest < ActionMailer::TestCase
  setup do
    %w[evaluator_mailer_new_evaluation_assigned evaluator_mailer_evaluation_submission_confirmation
       evaluator_mailer_evaluation_submission_confirmation_es].each do |name|
      load Rails.root.join("db/seeds/email_templates/#{name}.rb")
    end
  end

  test 'the actual assignment template renders for a phone-only paper applicant' do
    applicant = Current.instance.set(paper_context: true) do
      create(:constituent, email: nil, communication_preference: 'letter')
    end
    evaluation = evaluation_for(applicant)

    email = EvaluatorMailer.with(evaluation: evaluation).new_evaluation_assigned.message

    assert_equal [evaluation.evaluator.email], email.to
    assert_includes decoded_text_part(email), "- Phone: #{applicant.phone}"
    assert_includes decoded_text_part(email), '- Email: Not Provided'
    assert_includes decoded_text_part(email), Rails.application.routes.url_helpers.evaluators_evaluation_path(evaluation)
  end

  test 'the actual assignment template renders for an address-only paper applicant' do
    applicant = Current.instance.set(paper_context: true) do
      create(:constituent, email: nil, phone: nil, phone_type: 'letter', communication_preference: 'letter')
    end
    evaluation = evaluation_for(applicant)

    email = EvaluatorMailer.with(evaluation: evaluation).new_evaluation_assigned.message

    assert_equal [evaluation.evaluator.email], email.to
    assert_includes decoded_text_part(email), '- Phone: Not Provided'
    assert_includes decoded_text_part(email), '- Email: Not Provided'
    assert_includes decoded_text_part(email), applicant.physical_address_1
  end

  test 'assignment supplies managing guardian contacts without synthetic primary values' do
    first_guardian = create(:constituent)
    guardian = create(:constituent, locale: 'es', phone_type: 'text')
    applicant = guardian_contact_applicant(guardian, first_guardian: first_guardian)
    evaluation = evaluation_for(applicant, guardian: guardian)

    body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).new_evaluation_assigned.message)

    assert_includes body, "- Phone: #{guardian.phone}"
    assert_includes body, "- Email: #{guardian.email}"
    assert_includes body, '- Preferred Language: Spanish'
    assert_not_includes body, applicant.email
    assert_not_includes body, applicant.phone
    assert_not_includes body, first_guardian.email
  end

  test 'confirmation sends to the managing guardian in that guardians language' do
    first_guardian = create(:constituent, locale: 'en')
    guardian = create(:constituent, locale: 'es')
    applicant = guardian_contact_applicant(guardian, first_guardian: first_guardian)
    evaluation = evaluation_for(applicant, guardian: guardian)

    email = EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message

    assert_equal [guardian.email], email.to
    assert_equal 'Confirmación de Envío de Evaluación', email.subject
    assert_includes decoded_text_part(email), 'ha recibido su informe de evaluación'
  end

  test 'confirmation follows the managing guardians letter preference despite an independent applicant email' do
    guardian = create(:constituent, locale: 'es', communication_preference: 'letter')
    applicant = create(:constituent, locale: 'en', communication_preference: 'email',
                                     phone: '000-123-4567', dependent_phone: guardian.phone)
    applicant.update!(dependent_email: applicant.email)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)
    evaluation = evaluation_for(applicant, guardian: guardian)

    Letters::TextTemplateToPdfService.expects(:new).with do |**arguments|
      arguments[:recipient] == guardian && arguments[:locale] == 'es'
    end.returns(mock(queue_for_printing: true))

    assert_no_emails do
      EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_now
    end
  end

  test 'confirmation with preferred email and no email contact is explicitly not sent' do
    ensure_system_audit_actor!
    first_guardian = create(:constituent)
    guardian = create(:constituent, communication_preference: 'email')
    applicant = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                                     dependent_email: first_guardian.email)
    create(:guardian_relationship, guardian_user: first_guardian, dependent_user: applicant)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)
    evaluation = evaluation_for(applicant, guardian: guardian)

    assert_no_difference 'PrintQueueItem.count' do
      assert_no_emails do
        EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_now
      end
    end

    assert_equal 'missing_recipient', EmailDelivery::Current.denial_reason
    event = Event.where(action: EmailDelivery::Outcome::SUPPRESSED).order(:id).last
    assert_equal 'missing_recipient', event.metadata['reason']
    assert_equal 'EvaluatorMailer#evaluation_submission_confirmation', event.metadata['mail_action']
    assert_not_includes event.metadata.values, first_guardian.email
    assert_not Event.exists?(action: 'email_delivery_error')
  ensure
    EmailDelivery::Current.reset
  end

  test 'confirmation letter uses the managing guardian address and locale instead of the first guardian' do
    first_guardian = create(:constituent, locale: 'en')
    guardian = create(:constituent, locale: 'es', communication_preference: 'letter')
    applicant = guardian_contact_applicant(guardian, first_guardian: first_guardian)
    evaluation = evaluation_for(applicant, guardian: guardian)
    constructor = Letters::TextTemplateToPdfService.method(:new)
    letter = nil
    Letters::TextTemplateToPdfService.expects(:new).with do |**arguments|
      letter = constructor.call(**arguments)
      true
    end.returns(mock(queue_for_printing: true))

    assert_no_emails { EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_now }

    assert_equal guardian, letter.recipient
    assert_equal 'es', letter.template.locale
    assert_includes letter.send(:rendered_template).last, 'ha recibido su informe de evaluación'
  end

  test 'an edited confirmation template uses the report submission time rather than the appointment schedule' do
    submitted_at = 1.hour.ago.change(sec: 0)
    applicant = create(:constituent)
    application = create(:application, user: applicant)
    evaluation = create(:evaluation, :completed, application: application, constituent: applicant,
                                                 report_submitted_at: submitted_at, appointment_completed_at: 2.hours.ago)
    EmailTemplate.find_by!(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'en').update!(
      body: 'Report received: %<submission_date_formatted>s',
      variables: { 'required' => ['submission_date_formatted'], 'optional' => [] }
    )

    body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message)

    assert_includes body, submitted_at.strftime('%B %d, %Y at %I:%M %p %Z')
    assert_not_includes body, evaluation.evaluation_date.strftime('%B %d, %Y at %I:%M %p %Z')
  end

  test 'no suitable product confirmation states the outcome and rationale without working notes' do
    evaluation = completed_outcome_evaluation('no_suitable_product', 'The tested devices did not meet the communication need.')

    body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message)

    assert_includes body, 'The evaluation outcome and any product recommendations are:'
    assert_includes body, 'No suitable product was recommended.'
    assert_includes body, evaluation.recommendation_notes
    assert_includes body, 'does not confirm an equipment order or close your application'
    assert_not_includes body, evaluation.working_notes
    assert_not_includes body, 'the evaluator recommended the following'
  end

  test 'Spanish outside catalog confirmation includes the proposed device and staff review' do
    evaluation = completed_outcome_evaluation('outside_catalog', 'Dispositivo de comunicación modelo Z, pendiente de revisión.', locale: 'es')

    body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message)

    assert_includes body, 'El evaluador recomendó un producto que no está en el catálogo del programa.'
    assert_includes body, evaluation.recommendation_notes
    assert_includes body, 'El personal del programa debe revisar este resultado'
    assert_not_includes body, evaluation.working_notes
  end

  test 'a Spanish no suitable product letter includes the outcome without internal working notes' do
    evaluation = completed_outcome_evaluation('no_suitable_product', 'Los dispositivos probados no cubren la necesidad.', locale: 'es')
    evaluation.constituent.update!(communication_preference: 'letter')
    constructor = Letters::TextTemplateToPdfService.method(:new)
    letter = nil
    Letters::TextTemplateToPdfService.expects(:new).with do |**arguments|
      letter = constructor.call(**arguments)
      true
    end.returns(mock(queue_for_printing: true))

    assert_no_emails { EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.deliver_now }
    body = letter.send(:rendered_template).last

    assert_equal 'es', letter.template.locale
    assert_includes body, 'No se recomendó ningún producto adecuado.'
    assert_includes body, evaluation.recommendation_notes
    assert_not_includes body, evaluation.working_notes
  end

  test 'an existing stock or edited confirmation placeholder receives an explicit noncatalog outcome without reseeding' do
    evaluation = completed_outcome_evaluation('no_suitable_product', 'A different assessment approach is needed.')
    template = EmailTemplate.find_by!(name: 'evaluator_mailer_evaluation_submission_confirmation', format: :text, locale: 'en')
    template.update_columns(body: NeutralizeEvaluationConfirmationOutcomeCopy::OLD_BODIES.fetch('en'))

    body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message)
    assert_includes body, 'No suitable product was recommended.'
    assert_includes body, evaluation.recommendation_notes

    template.update!(syntax: :liquid, body: 'Report outcome: {{ recommended_products_text_list }}',
                     variables: { 'required' => ['recommended_products_text_list'], 'optional' => [] })
    edited_body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message)

    assert_includes edited_body, 'Report outcome: No suitable product was recommended.'
    assert_includes edited_body, evaluation.recommendation_notes
    assert_not_includes edited_body, evaluation.working_notes
  end

  test 'catalog confirmation keeps optional recommendation details separate from internal working notes' do
    applicant = create(:constituent)
    application = create(:application, user: applicant)
    evaluation = create(:evaluation, :completed, application: application, constituent: applicant,
                                                 recommendation_notes: 'Consider a compatible accessory after staff review.',
                                                 working_notes: 'Internal scheduling note not submitted in the report.')

    body = decoded_text_part(EvaluatorMailer.with(evaluation: evaluation).evaluation_submission_confirmation.message)

    evaluation.recommended_products.each { |product| assert_includes body, product.name }
    assert_includes body, evaluation.recommendation_notes
    assert_not_includes body, evaluation.working_notes
  end

  private

  def completed_outcome_evaluation(outcome, recommendation_notes, locale: 'en')
    applicant = create(:constituent, locale: locale)
    application = create(:application, user: applicant)
    evaluation = build(:evaluation, :completed, application: application, constituent: applicant,
                                                recommendation_outcome: outcome, recommendation_notes: recommendation_notes,
                                                working_notes: 'Internal scheduling note not submitted in the report.')
    evaluation.recommended_products = []
    evaluation.save!
    evaluation
  end

  def evaluation_for(applicant, guardian: nil)
    application = create(:application, user: applicant, managing_guardian: guardian)
    create(:evaluation, application: application, constituent: applicant, evaluation_date: nil)
  end

  def guardian_contact_applicant(guardian, first_guardian:)
    applicant = create(:constituent, email: "dependent-#{SecureRandom.uuid}@system.matvulcan.local",
                                     dependent_email: guardian.email,
                                     phone: '000-123-4567', dependent_phone: guardian.phone)
    create(:guardian_relationship, guardian_user: first_guardian, dependent_user: applicant)
    create(:guardian_relationship, guardian_user: guardian, dependent_user: applicant)
    applicant
  end
end
