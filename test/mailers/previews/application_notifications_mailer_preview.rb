# frozen_string_literal: true

class ApplicationNotificationsMailerPreview < ActionMailer::Preview
  def proof_approved
    application = Application.first
    proof_review = ProofReview.first
    ApplicationNotificationsMailer.proof_approved(application, proof_review)
  end

  def proof_rejected
    application = Application.first
    proof_review = ProofReview.first
    ApplicationNotificationsMailer.proof_rejected(application, proof_review)
  end

  def max_rejections_reached
    application = Application.first
    ApplicationNotificationsMailer.max_rejections_reached(application)
  end

  def proof_needs_review_reminder
    admin = Admin.first
    applications = Application.limit(5)
    ApplicationNotificationsMailer.proof_needs_review_reminder(admin, applications)
  end

  def account_created
    constituent = Constituent.first
    ApplicationNotificationsMailer.account_created(constituent)
  end

  def income_threshold_exceeded
    constituent_params = {
      first_name: 'John',
      last_name: 'Doe',
      email: 'john.doe@example.com',
      phone: '555-123-4567'
    }

    notification_params = {
      household_size: 2,
      annual_income: 100_000,
      communication_preference: 'email',
      additional_notes: 'Income exceeds threshold'
    }

    ApplicationNotificationsMailer.income_threshold_exceeded(constituent_params, notification_params)
  end
end
