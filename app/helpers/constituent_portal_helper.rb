module ConstituentPortalHelper
  # Per-form key identifying one dependent-creation submission.
  #
  # Reuses the submitted value when the form is re-rendered after a failure, so a guardian who
  # corrects a validation error and resubmits is still making the *same* request. Nothing was
  # persisted by the failed attempt, so the server sees an unspent key and creates normally;
  # carrying it forward matters only if that attempt turns out to have committed after all.
  def portal_creation_key_for_form
    submitted = params[:portal_creation_key].to_s
    return submitted if submitted.match?(ConstituentPortal::DependentsController::PORTAL_CREATION_KEY_FORMAT)

    SecureRandom.hex(16)
  end

  def formatted_timestamp(notification)
    timestamp = if notification.metadata.present? && notification.metadata.is_a?(Hash) && notification.metadata['timestamp'].present?
                  begin
                    Time.zone.parse(notification.metadata['timestamp'])
                  rescue StandardError
                    notification.created_at
                  end
                else
                  notification.created_at
                end

    timestamp.strftime('%B %d, %Y at %I:%M %p')
  end

  def active_disabilities_list(user)
    disabilities = []
    disabilities << 'Hearing' if user.hearing_disability
    disabilities << 'Vision' if user.vision_disability
    disabilities << 'Speech' if user.speech_disability
    disabilities << 'Mobility' if user.mobility_disability
    disabilities << 'Cognition' if user.cognition_disability
    disabilities
  end
end
