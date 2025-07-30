# frozen_string_literal: true

class ApplicationStatus
  def initialize(application)
    @application = application
  end

  def send_back!(actor: nil)
    @application.update(status: :needs_information)

    # Log the audit event
    AuditEventService.log(
      action: 'application_sent_back',
      actor: actor,
      auditable: @application,
      metadata: { reason: 'Additional information required.' }
    )

    # Send the notification
    NotificationService.create_and_deliver!(
      type: 'application_sent_back',
      recipient: @application.user,
      actor: actor,
      notifiable: @application,
      metadata: { reason: 'Additional information required.' },
      channel: :email
    )
  end
end
