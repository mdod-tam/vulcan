# frozen_string_literal: true

module EmailTemplates
  # Replaces the old eligibility paragraph without resetting staff-edited templates.
  class IccProofRollout
    VARIABLE = 'request_explanation'
    LEGACY_INTROS = {
      'requested' => {
        'en' => 'We are reviewing your MAT application and still need your %<proof>s before we can continue processing your application.',
        'es' => 'Estamos revisando su solicitud de MAT y todavía necesitamos su %<proof>s antes de poder continuar con el trámite de su solicitud.'
      },
      'rejected' => {
        'en' => 'Thank you for submitting your %<proof>s for your MAT application. We reviewed it and need a corrected copy ' \
                'before we can continue processing your application.',
        'es' => 'Gracias por enviar su %<proof>s para su solicitud de MAT. La revisamos y necesitamos una copia corregida ' \
                'antes de poder continuar con el trámite de su solicitud.'
      }
    }.freeze
    REJECTION_INTROS = { 'en' => 'We reviewed your %<proof>s.', 'es' => 'Revisamos su %<proof>s.' }.freeze

    def self.apply!(actor:)
      EmailTemplate.transaction(requires_new: true) do
        templates = load_templates
        sync_flags = templates.to_h { |template| [template.id, template.locale_needs_sync?] }
        updated = templates.count { |template| upgrade!(template, actor:) }
        templates.each do |template|
          template.reload
          original_sync_flag = sync_flags.fetch(template.id)
          template.update!(locale_needs_sync: original_sync_flag) if template.locale_needs_sync? != original_sync_flag
        end
        updated
      end
    end

    def self.load_templates
      LEGACY_INTROS.flat_map do |action, locales|
        locales.keys.map do |locale|
          EmailTemplate.lock.find_by!(name: "application_notifications_proof_#{action}", format: :text, locale:)
        end
      end
    end

    def self.upgrade!(template, actor:)
      variables = template.variables.merge(
        'required' => template.required_variables | [VARIABLE],
        'optional' => template.optional_variables - [VARIABLE]
      )
      body = upgraded_body(template)
      return false if body == template.body && variables == template.variables

      template.update!(body:, variables:, updated_by: actor)
      event = AuditEventService.log(action: 'email_template_updated', actor:, auditable: template,
                                    metadata: { operation_id: SecureRandom.uuid, locale: template.locale, variable_added: VARIABLE })
      raise 'The proof outreach update was not audited.' unless event

      true
    end

    def self.upgraded_body(template)
      body_variables = Renderer.extract_variables(subject: '', body: template.body, syntax: template.render_syntax)
      return template.body if body_variables.include?(VARIABLE)

      action = template.name.delete_prefix('application_notifications_proof_')
      proof = placeholder(template, 'proof_type_formatted')
      old_intro = format(LEGACY_INTROS.fetch(action).fetch(template.locale), proof:)
      lines = template.body.lines
      matches = lines.each_index.select { |index| lines[index].strip == old_intro }
      raise ArgumentError, "Review the customized proof #{action} paragraph in #{template.locale.upcase} before applying the rollout." unless matches.one?

      new_intro = placeholder(template, VARIABLE)
      new_intro = [format(REJECTION_INTROS.fetch(template.locale), proof:), new_intro].join("\n\n") if action == 'rejected'
      index = matches.sole
      lines[index] = lines[index].end_with?("\n") ? "#{new_intro}\n" : new_intro
      lines.join
    end

    def self.placeholder(template, name)
      template.liquid? ? "{{ #{name} }}" : "%<#{name}>s"
    end

    private_class_method :load_templates, :upgrade!, :upgraded_body, :placeholder
  end
end
