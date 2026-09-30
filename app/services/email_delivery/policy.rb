# frozen_string_literal: true

module EmailDelivery
  # Versioned captures distinguish old email-only authorization from the All contract.
  # Retain the namespace and mail job class so queued payloads have a deliberate disposition.
  class Policy
    CONTEXT_VERSION = 2

    def self.capture(mail_action:, params: {}, request_id: SecureRandom.uuid)
      entry = Catalog.mail_action(mail_action)
      base = { 'version' => CONTEXT_VERSION, 'request_id' => request_id, 'delivery_correlation_id' => SecureRandom.uuid, 'mail_action' => mail_action.to_s,
               'notification_id' => Current.notification_id || params[:notification_id] || params['notification_id'] }.compact
      return base.merge('configuration_error' => 'unclassified_action') unless entry

      name = entry.template || test_template_name(entry, params)
      return base.merge('configuration_error' => 'unclassified_action') if EmailTemplate.fragment_name?(name)

      build_capture(entry, base, params, name)
    rescue ConfigurationError, ActiveRecord::ActiveRecordError => e
      base.merge('configuration_error' => e.class.name)
    end

    def self.build_capture(entry, base, params, name)
      mail_action = base.fetch('mail_action')
      category = Catalog.category_for(mail_action, params: params)
      controls = [control!(ALL_CONTROL)]
      controls << control!(EmailDelivery.category_control(category)) if category
      channels = Catalog.channels_for(mail_action).to_h do |channel|
        channel_name = CHANNEL_CONTROLS[channel]
        [channel, channel_name ? channel_scope_for(channel_name) : nil]
      end
      context = base.merge('category' => category, 'template_name' => name,
                           'template_format' => (params[:format] || params['format'] || 'text').to_s,
                           'scopes' => controls.map { |control| scope_for(control) }, 'channels' => channels,
                           'templates' => template_rows(entry, params).map { |row| template_scope_for(row) })
      context['denied_channels'] = initial_denials(context)
      context
    end
    private_class_method :build_capture

    # Email Off cannot poison an eligible letter route.
    def self.initial_denials(context)
      context.fetch('channels').keys.filter_map do |channel|
        decision = verify_controls(context, channel)
        [channel, { 'outcome' => decision.outcome.to_s, 'reason' => decision.reason }] unless decision.allowed?
      end.to_h
    end
    private_class_method :initial_denials

    def self.verify(context, channel: 'email')
      return Decision.suppressed(:legacy_context_missing) if context.blank? || context['version'] != CONTEXT_VERSION
      return Decision.configuration_error(context['configuration_error']) if context['configuration_error']

      verify_delivery(context['mail_action'], context, channel: channel)
    end

    def self.verify_delivery(mail_action, context, channel: 'email')
      channel = channel.to_s
      return Decision.configuration_error(:unclassified_action) unless Catalog.channels_for(mail_action).include?(channel)
      return Decision.suppressed(:legacy_context_missing) if context.blank? || context['version'] != CONTEXT_VERSION
      return Decision.configuration_error(context['configuration_error']) if context['configuration_error']
      return Decision.suppressed(:delivery_identity_changed) unless context['mail_action'] == mail_action.to_s

      if (denial = context.dig('denied_channels', channel))
        return Decision.configuration_error(denial['reason']) if denial['outcome'] == 'configuration_error'

        return Decision.suppressed(denial['reason'])
      end

      verify_controls(context, channel)
    end

    def self.verify_any(mail_action, context)
      decisions = Catalog.channels_for(mail_action).map { |channel| verify_delivery(mail_action, context, channel: channel) }
      return Decision.configuration_error(:unclassified_action) if decisions.empty?
      return Decision.allowed if decisions.any?(&:allowed?)

      decisions.find(&:configuration_error?) || decisions.first
    end

    # Print release locks the same controls as the writer before locking print items.
    # Storage, rendering and network I/O must stay outside this transaction.
    def self.with_locked_controls(contexts, channel:)
      FeatureFlag.transaction do
        scopes = contexts.flat_map { |context| Array(context&.dig('scopes')) + [context&.dig('channels', channel.to_s)] }.compact
        FeatureFlag.where(id: scopes.pluck('id')).order(:id).lock.load
        templates = contexts.flat_map { |context| Array(context&.dig('templates')) }
        EmailTemplate.where(id: templates.pluck('id')).order(:id).lock.load
        yield
      end
    end

    def self.template_rows(entry, params)
      return EmailTemplate.none if entry.nil?

      name = entry.template || test_template_name(entry, params)
      return EmailTemplate.none if name.blank?

      format = entry.template ? :text : (params[:format] || params['format'] || :text)
      EmailTemplate.where(name: name, format: format).order(:id)
    end

    def self.verify_controls(context, channel)
      return Decision.configuration_error(:uncaptured_channel) unless context.fetch('channels', {}).key?(channel)

      scopes = Array(context['scopes'])
      expected = [ALL_CONTROL]
      expected << EmailDelivery.category_control(context['category']) if context['category']
      return Decision.configuration_error(:invalid_control_context) unless scopes.pluck('control').sort == expected.sort

      channel_scope = context.dig('channels', channel)
      return Decision.configuration_error(:invalid_channel_context) unless channel_scope&.dig('control') == CHANNEL_CONTROLS[channel]

      # Explain the first applicable refusal: All, channel, category, then template.
      [scopes.first, channel_scope, *scopes.drop(1)].compact.each do |scope|
        decision = verify_scope(scope)
        return decision unless decision.allowed?
      end
      Array(context['templates']).each do |scope|
        decision = verify_template(scope)
        return decision unless decision.allowed?
      end
      verify_template_identity(context)
    rescue ConfigurationError, ActiveRecord::ActiveRecordError => e
      Decision.configuration_error(e.class.name)
    end
    private_class_method :verify_controls

    def self.verify_scope(scope)
      control = control!(scope['control'])
      return Decision.suppressed(:pending_canceled) if control.id != scope['id']
      return Decision.suppressed(disabled_reason(control)) unless control.enabled
      return Decision.suppressed(:pending_canceled) if control.delivery_generation != scope['generation']

      Decision.allowed
    end
    private_class_method :verify_scope

    def self.verify_template(scope)
      template = EmailTemplate.find_by(id: scope['id'])
      return Decision.suppressed(:pending_canceled) unless template && template.name == scope['name'] && template.locale == scope['locale']
      return Decision.suppressed(:template_disabled) unless template.enabled
      return Decision.suppressed(:pending_canceled) if template.delivery_generation != scope['generation']

      Decision.allowed
    end
    private_class_method :verify_template

    def self.verify_template_identity(context)
      return Decision.allowed if context['template_name'].blank?

      ids = EmailTemplate.where(name: context['template_name'], format: context['template_format']).order(:id).pluck(:id)
      return Decision.suppressed(:pending_canceled) unless ids == Array(context['templates']).pluck('id')

      Decision.allowed
    end
    private_class_method :verify_template_identity

    def self.channel_scope_for(name)
      scope_for(control!(name))
    rescue ConfigurationError, ActiveRecord::ActiveRecordError
      # A missing sibling channel must not invalidate an otherwise eligible letter route.
      { 'control' => name, 'id' => nil, 'generation' => nil }
    end
    private_class_method :channel_scope_for

    def self.control!(name)
      raise ConfigurationError, 'Unknown communication control' unless CONTROL_NAMES.include?(name)

      FeatureFlag.find_by(name: name) || raise(ConfigurationError, "Missing #{name} control")
    end
    private_class_method :control!

    def self.scope_for(control)
      { 'control' => control.name, 'id' => control.id, 'generation' => control.delivery_generation }
    end
    private_class_method :scope_for

    def self.template_scope_for(template)
      { 'name' => template.name, 'locale' => template.locale, 'id' => template.id, 'generation' => template.delivery_generation }
    end
    private_class_method :template_scope_for

    def self.test_template_name(entry, params)
      params[:template_name] || params['template_name'] if entry.category == 'from_test_template'
    end
    private_class_method :test_template_name

    def self.disabled_reason(control)
      return :all_disabled if control.name == ALL_CONTROL
      return :global_disabled if control.name == GLOBAL_CONTROL
      return :letters_disabled if control.name == CHANNEL_CONTROLS['letter']
      return :sms_disabled if control.name == CHANNEL_CONTROLS['sms']

      :category_disabled
    end
    private_class_method :disabled_reason
  end
end
