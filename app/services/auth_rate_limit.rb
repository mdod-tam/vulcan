# frozen_string_literal: true

class AuthRateLimit
  class ExceededError < StandardError; end

  DEFAULT_PERIOD_HOURS = 1
  MAX_POLICY_VALUE = 100
  MAX_POLICY_PERIOD_HOURS = 168
  SAFE_IDENTIFIER_PATTERN = /\A[a-f0-9]{64}\z/i

  ALLOWED_SCOPES_FOR = {
    sign_in_attempt: %i[ip].freeze,
    account_access: %i[ip contact_ip user_ip].freeze,
    account_recovery: %i[contact_ip user_ip ip].freeze
  }.freeze

  DEFAULT_MAX_FOR = {
    sign_in_attempt: { ip: 20 },
    account_access: { ip: 5, contact_ip: 5, user_ip: 5 },
    account_recovery: { contact_ip: 5, ip: 5, user_ip: 3 }
  }.freeze

  def self.check!(action:, scope:, request: nil, submitted_contact: nil, user_id: nil)
    identifier = derive_identifier(
      scope: scope,
      request: request,
      submitted_contact: submitted_contact,
      user_id: user_id
    )

    new(action: action, scope: scope, identifier: identifier).check!
  end

  def self.limit_config_for(action, scope)
    action = action.to_sym
    scope = scope.to_sym
    return nil unless Policy::AUTH_RATE_LIMIT_ACTIONS.include?(action)
    return nil unless allowed_scope?(action, scope)

    max = normalize_max(Policy.get("#{action}_rate_limit_#{scope}"), action, scope)
    period_hours = normalize_period(Policy.get("#{action}_rate_period"))

    { max: max, period: period_hours.hours }
  end

  def self.allowed_scope?(action, scope)
    ALLOWED_SCOPES_FOR.fetch(action.to_sym, []).include?(scope.to_sym)
  end

  def self.normalize_max(value, action, scope)
    return default_max(action, scope) if value.nil? || !value.is_a?(Integer) || value <= 0 || value > MAX_POLICY_VALUE

    value
  end

  def self.normalize_period(value)
    return DEFAULT_PERIOD_HOURS if value.nil? || !value.is_a?(Integer) || value <= 0 || value > MAX_POLICY_PERIOD_HOURS

    value
  end

  def self.default_max(action, scope)
    action = action.to_sym
    scope = scope.to_sym
    return nil unless allowed_scope?(action, scope)

    DEFAULT_MAX_FOR.fetch(action).fetch(scope)
  end

  def self.contact_digest(submitted_contact)
    canonical = canonical_submitted_contact(submitted_contact)
    return 'blank' if canonical.blank?

    secret = Rails.application.key_generator.generate_key('auth-rate-limit-submitted-contact', 32)
    OpenSSL::HMAC.hexdigest('SHA256', secret, canonical)
  end

  def self.canonical_submitted_contact(contact)
    stripped = contact.to_s.strip
    return nil if stripped.blank?

    if User.login_identifier_looks_like_email?(stripped)
      normalized = User.normalize_email(stripped)
      return normalized if normalized.present? && User.login_identifier_valid_email?(stripped)

      return nil
    end

    User.normalize_phone(stripped)
  end

  def self.request_ip_digest(request)
    secret = Rails.application.key_generator.generate_key('auth-rate-limit-request-ip', 32)
    OpenSSL::HMAC.hexdigest('SHA256', secret, request.remote_ip.to_s)
  end

  def self.cache_identifier(contact_digest:, request_ip_digest:, user_id: nil)
    parts = [contact_digest, request_ip_digest]
    parts << "user:#{user_id}" if user_id.present?
    Digest::SHA256.hexdigest(parts.join(':'))
  end

  def self.derive_identifier(scope:, request:, submitted_contact:, user_id:)
    case scope.to_sym
    when :ip
      raise ArgumentError, 'request is required for ip scope' if request.blank?

      request_ip_digest(request)
    when :contact_ip
      raise ArgumentError, 'request is required for contact_ip scope' if request.blank?
      raise ArgumentError, 'submitted_contact is required for contact_ip scope' if submitted_contact.nil?

      cache_identifier(
        contact_digest: contact_digest(submitted_contact),
        request_ip_digest: request_ip_digest(request)
      )
    when :user_ip
      raise ArgumentError, 'request is required for user_ip scope' if request.blank?
      raise ArgumentError, 'user_id is required for user_ip scope' if user_id.blank?

      cache_identifier(
        contact_digest: 'user',
        request_ip_digest: request_ip_digest(request),
        user_id: user_id
      )
    else
      raise ArgumentError, "Unknown auth rate limit scope: #{scope}"
    end
  end
  private_class_method :derive_identifier

  def initialize(action:, scope:, identifier:)
    @action = action.to_sym
    @scope = scope.to_sym
    @identifier = identifier
    @limit = AuthRateLimit.limit_config_for(@action, @scope)
    validate_identifier!
  end

  def check!
    raise ArgumentError, "Unknown auth rate limit action/scope: #{@action}/#{@scope}" unless @limit

    count = increment_count
    return if count <= @limit[:max]

    raise ExceededError,
          "Rate limit exceeded for #{@action} (#{@scope}): maximum #{@limit[:max]} per #{@limit[:period] / 1.hour} hour(s)"
  end

  def current_usage_count
    Rails.cache.read(cache_key).to_i
  end

  private

  def validate_identifier!
    return if @identifier.to_s.match?(SAFE_IDENTIFIER_PATTERN)

    raise ArgumentError, 'identifier must be a 64-character hex digest derived by AuthRateLimit'
  end

  def cache_key
    "auth_rate_limit:#{@action}:#{@scope}:#{@identifier}"
  end

  def increment_count
    Rails.cache.increment(cache_key, expires_in: @limit[:period]).to_i
  end
end
