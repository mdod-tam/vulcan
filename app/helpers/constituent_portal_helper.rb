module ConstituentPortalHelper
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
