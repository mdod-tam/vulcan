# frozen_string_literal: true

namespace :email_templates do
  desc 'Update the English and Spanish proof request and rejection paragraphs for iCanConnect'
  task update_icc_proof_outreach: :environment do
    actor = User.system_user || abort('Provision the system audit administrator before updating templates.')
    count = EmailTemplates::IccProofRollout.apply!(actor:)
    puts "Updated #{count} proof outreach templates."
  end

  desc 'Render sample proof outreach for pending MAT and approved iCanConnect applicants without sending'
  task preview_icc_proof_outreach: :environment do
    %w[en es].each do |locale|
      %w[requested rejected].each do |action|
        EmailTemplate.find_by!(name: "application_notifications_proof_#{action}", format: :text, locale:, enabled: true)
      end
      recipient = Users::Constituent.new(first_name: 'Alex', last_name: 'Example', email: 'alex@example.com', locale:)
      form = SecureRequestForm.new(recipient:, delivery_owner: recipient, recipient_channel: :email, recipient_email: recipient.email)
      upload_url = 'https://example.com/sample-secure-upload'
      %i[in_progress approved].each do |status|
        application = Application.new(user: recipient, status:, fulfillment_type: :voucher)
        review = ProofReview.new(application:, proof_type: :income, status: :rejected,
                                 rejection_reason: locale == 'es' ? 'La foto no se puede leer.' : 'The photo is too blurry to read.')
        messages = [
          ApplicationNotificationsMailer.proof_requested(application, :income, secure_upload_url: upload_url, secure_request_form: form),
          ApplicationNotificationsMailer.proof_rejected(application, review, secure_upload_url: upload_url, secure_request_form: form)
        ]
        messages.each do |delivery|
          message = delivery.message
          puts "\n#{locale.upcase} / #{status} / #{message.subject}\n\n#{message.text_part&.body&.decoded || message.body.decoded}"
        end
      end
    end
  end
end
