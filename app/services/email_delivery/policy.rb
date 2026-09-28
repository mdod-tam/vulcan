# frozen_string_literal: true

module EmailDelivery
  # Captures the controls an email depends on when it is requested, and verifies them before it
  # is sent: the master control, the email's category, and every locale row of its template pair.
  # Verification compares row ids and generations, so a control or template turned off in the
  # meantime, or a row that was recreated, cancels the email even if everything is on now.
  class Policy
    def self.capture(mail_action:, params: {}, request_id: SecureRandom.uuid)
      base = { 'request_id' => request_id, 'mail_action' => mail_action.to_s, 'notification_id' => Current.notification_id }.compact
      entry = Catalog.mail_action(mail_action)
      controls = [global_control!]
      if entry
        # A shared fragment is never sent on its own, not even as a test.
        return base.merge('configuration_error' => 'unclassified_action') if EmailTemplate.fragment_name?(test_template_name(entry, params))

        # A test send of a template no email uses has no category; the master control and the
        # template's own setting still apply.
        category = Catalog.category_for(mail_action, params: params)
        controls << category_control!(category) if category
      end

      context = base.merge('scopes' => controls.map { |control| scope_for(control) },
                           'templates' => template_rows(entry, params).map { |row| template_scope_for(row) })
      # An email requested while a control is off stays denied; turning the control back on
      # authorizes only emails requested afterwards. A letter route in the same action still runs.
      decision = verify_controls(context)
      return context if decision.allowed?
      return context.merge('configuration_error' => decision.reason) if decision.configuration_error?

      context.merge('denied_reason' => decision.reason)
    rescue ConfigurationError, ActiveRecord::ActiveRecordError => e
      base.merge('configuration_error' => e.class.name)
    end

    def self.verify(context)
      return Decision.suppressed(:legacy_context_missing) if context.blank?
      return Decision.configuration_error(context['configuration_error']) if context['configuration_error']
      return Decision.suppressed(context['denied_reason']) if context['denied_reason']

      verify_controls(context)
    end

    def self.verify_controls(context)
      global_control!
      checks = Array(context['scopes']).map { |scope| verify_scope(scope) } +
               Array(context['templates']).map { |scope| verify_template(scope) }
      checks.find { |decision| !decision.allowed? } || Decision.allowed
    rescue ConfigurationError, ActiveRecord::ActiveRecordError => e
      Decision.configuration_error(e.class.name)
    end
    private_class_method :verify_controls

    # verify, plus the catalog: an action nobody classified is a configuration defect.
    def self.verify_delivery(mail_action, context)
      return Decision.configuration_error(:unclassified_action) if Catalog.mail_action(mail_action).nil?

      verify(context)
    end

    # The template pair a mail action renders: every locale of that name and format.
    def self.template_rows(entry, params)
      return EmailTemplate.none if entry.nil?

      name = entry.template || test_template_name(entry, params)
      return EmailTemplate.none if name.blank?

      format = entry.template ? :text : (params[:format] || params['format'] || :text)
      EmailTemplate.where(name: name, format: format).order(:id)
    end

    def self.test_template_name(entry, params)
      return unless entry.category == 'from_test_template'

      params[:template_name] || params['template_name']
    end
    private_class_method :test_template_name

    def self.verify_scope(scope)
      control = FeatureFlag.find_by(id: scope['id'])
      return Decision.suppressed(:pending_canceled) if control.nil? || control.name != scope['control']
      return Decision.suppressed(disabled_reason(control)) unless control.enabled
      return Decision.suppressed(:pending_canceled) if control.delivery_generation != scope['generation']

      Decision.allowed
    end
    private_class_method :verify_scope

    def self.verify_template(scope)
      template = EmailTemplate.find_by(id: scope['id'])
      return Decision.suppressed(:pending_canceled) if template.nil? || template.name != scope['name']
      return Decision.suppressed(:template_disabled) unless template.enabled
      return Decision.suppressed(:pending_canceled) if template.delivery_generation != scope['generation']

      Decision.allowed
    end
    private_class_method :verify_template

    def self.global_control!
      FeatureFlag.find_by(name: GLOBAL_CONTROL) || raise(ConfigurationError, "Missing #{GLOBAL_CONTROL} control")
    end
    private_class_method :global_control!

    def self.category_control!(category)
      name = EmailDelivery.category_control(category)
      FeatureFlag.find_by(name: name) || raise(ConfigurationError, "Missing #{name} control")
    end
    private_class_method :category_control!

    def self.scope_for(control)
      { 'control' => control.name, 'id' => control.id, 'generation' => control.delivery_generation }
    end
    private_class_method :scope_for

    def self.template_scope_for(template)
      { 'name' => template.name, 'locale' => template.locale, 'id' => template.id,
        'generation' => template.delivery_generation }
    end
    private_class_method :template_scope_for

    def self.disabled_reason(control)
      control.name == GLOBAL_CONTROL ? :global_disabled : :category_disabled
    end
    private_class_method :disabled_reason
  end
end
