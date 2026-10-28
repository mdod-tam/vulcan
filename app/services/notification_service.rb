# frozen_string_literal: true

class NotificationService
  VALID_CHANNELS = %i[email letter sms].freeze
  PROOF_REJECTION_ACTIONS = %w[proof_rejected id_proof_rejected income_proof_rejected residency_proof_rejected].freeze

  # Channel records the requested route; the mailer owns the actual email/letter route.
  # Failure returns nil, including record-only creation failures.
  def self.create_and_deliver!(type:, recipient:, **options)
    new(type: type.to_s, recipient: recipient, options: options.symbolize_keys).call
  rescue StandardError => e
    recipient_id = recipient.id if recipient.respond_to?(:id)
    Rails.logger.error "NotificationService: Failed to create and deliver notification (type: #{type}, recipient_id: #{recipient_id}): #{e.class.name}"
    nil
  end

  # A returned row is not proof of delivery. Record-only rows have no delivery status.
  def self.delivery_outcome(notification)
    return :failed if notification.nil? || notification.error_delivery_status?

    notification.delivery_status&.to_sym || :recorded
  end

  def initialize(type:, recipient:, options:)
    @type = type
    @recipient = recipient
    @options = options
    @channel = coerce_channel(options.fetch(:channel, :email))
    @should_deliver = options.fetch(:deliver, true) ? true : false
    @audited = !!options[:audit]
  end

  def call
    raise ArgumentError, 'Notification type and recipient are required' if @type.blank? || @recipient.blank?

    if PROOF_REJECTION_ACTIONS.include?(@type)
      Rails.logger.error "NotificationService: Refused to create '#{@type}' notification. Use Applications::RequestProofResubmission."
      return nil
    end

    notification = create_notification
    return nil unless notification

    EmailDelivery::NotificationDispatch.new(notification, channel: @channel).call if @should_deliver
    notification
  end

  private

  def create_notification
    actor = @options[:actor] || default_actor
    notifiable = @options[:notifiable]
    Rails.logger.info "Creating notification: #{@type} for #{@recipient.class.name}##{@recipient.id} " \
                      "by #{actor&.class&.name}##{actor&.id} about #{notifiable&.class&.name}##{notifiable&.id} via #{@channel}"
    notification = Notification.create!(recipient: @recipient, actor: actor, action: @type, notifiable: notifiable,
                                        metadata: finalized_metadata, audited: @audited)
    ActiveSupport::Notifications.instrument('notification_service.create', notification: notification)
    notification
  rescue ActiveRecord::RecordInvalid => e
    record_creation_error(e, 'creation_validation')
  rescue StandardError => e
    record_creation_error(e, 'creation_general')
  end

  def record_creation_error(error, stage)
    ActiveSupport::Notifications.instrument('notification_service.error', type: @type, error_class: error.class.name, stage: stage)
    Rails.logger.error "NotificationService: Creation failed for type '#{@type}': #{error.class.name}"
    nil
  end

  def default_actor
    User.admins.first || User.find_by(email: ProgramContact.support_email)
  end

  def finalized_metadata
    raw = @options[:metadata]
    unless raw.nil? || raw.is_a?(Hash)
      Rails.logger.warn "NotificationService: Metadata received as #{raw.class.name}, but metadata must be a Hash. Ignoring non-hash metadata."
      raw = nil
    end
    metadata = (raw || {}).deep_stringify_keys
    timestamp = metadata['timestamp']
    metadata['timestamp'] = case timestamp
                            when Time, ActiveSupport::TimeWithZone then timestamp.iso8601
                            when String then timestamp
                            else Time.current.iso8601
                            end
    metadata.merge('channel' => @channel.to_s)
  end

  def coerce_channel(value)
    channel = value.to_s.strip.downcase.to_sym
    return channel if VALID_CHANNELS.include?(channel)

    Rails.logger.warn "NotificationService: Invalid channel '#{value}' provided. Coercing to default channel: email"
    :email
  end
end
