# frozen_string_literal: true

module Admin
  module EmailTemplatesHelper
    LAYOUT_PLACEHOLDER_NAMES = %w[header_text footer_text header_html footer_html].freeze

    def template_locale_label(locale)
      case locale.to_s
      when 'en' then 'English (EN)'
      when 'es' then 'Spanish (ES)'
      else locale.to_s.upcase
      end
    end

    def counterpart_locale(locale)
      locale.to_s == 'en' ? 'es' : 'en'
    end

    def template_last_updated_text(template)
      return 'Last updated: unavailable' unless template&.updated_at

      editor_name = template.updated_by&.full_name.presence || 'System'
      formatted_time = template.updated_at.strftime('%B %d, %Y at %I:%M %p')
      "Last updated (#{template.locale.to_s.upcase}): #{formatted_time} by #{editor_name}"
    end

    def template_sync_status(template)
      template&.locale_needs_sync? ? 'Needs sync' : 'In sync'
    end

    def template_sync_badge_classes(template)
      badge_classes(template&.locale_needs_sync? ? :warning : :success)
    end

    def template_syntax_label(template_or_syntax)
      syntax = template_or_syntax.respond_to?(:render_syntax) ? template_or_syntax.render_syntax : template_or_syntax.to_s

      case syntax
      when 'liquid'
        'Liquid'
      else
        'Standard'
      end
    end

    def template_syntax_badge_classes(template)
      badge_classes(template&.render_syntax == 'liquid' ? :info : :neutral)
    end

    def email_template_syntax_options(template)
      options = [['Standard (%<name>s)', 'legacy_percent']]
      return options unless template&.text?

      options << ['Liquid ({{ name }})', 'liquid']
      options
    end

    def variable_placeholder_for(template, variable, syntax: nil)
      selected_syntax = syntax.presence || template.render_syntax
      selected_syntax.to_s == 'liquid' ? "{{ #{variable} }}" : "%<#{variable}>s"
    end

    def variable_display_label(variable)
      variable.to_s.tr('._', ' ').squish.titleize
    end

    def variable_option_label(template, variable, syntax: nil)
      "#{variable_display_label(variable)} - #{variable_placeholder_for(template, variable, syntax: syntax)}"
    end

    def placeholder_style_help_classes(style, template)
      visible = template.render_syntax == style.to_s
      classes = ['rounded-md border px-3 py-2 text-sm']
      classes.unshift('hidden') unless visible
      classes.join(' ')
    end

    def standard_placeholder_style_help_classes(template)
      "#{placeholder_style_help_classes(:legacy_percent, template)} border-gray-200 bg-gray-50 text-gray-600"
    end

    def liquid_placeholder_style_help_classes(template)
      "#{placeholder_style_help_classes(:liquid, template)} border-info-200 bg-info-50 text-info-900"
    end

    def display_template_body(template)
      template.body.to_s.lines.map { |line| display_template_body_line(line) }.join
    end

    def template_render_error_message(error_or_messages)
      messages = Array(error_or_messages.respond_to?(:message) ? error_or_messages.message : error_or_messages)
                 .map(&:to_s)
                 .uniq
      message = messages.join(', ')

      return message if admin_actionable_template_error?(message)

      return 'This template has a placeholder problem. Use Insert Variable, then preview again.' if template_placeholder_error?(message)

      'This template could not be previewed. Check the placeholders and try again.'
    end

    def template_validation_error_messages(messages)
      Array(messages).map { |message| template_validation_error_message(message) }.uniq
    end

    def template_validation_error_message(message)
      cleaned_message = message.to_s.sub(/\A(?:Base|Body|Subject|Syntax) /, '')

      return 'This template has a placeholder problem. Use Insert Variable, then save again.' if invalid_liquid_syntax_error?(cleaned_message)

      if (match = cleaned_message.match(/\AMust include the required variable (.+) in the subject or body\z/))
        return "Add the required variable #{match[1]} using Insert Variable."
      end

      cleaned_message
    end

    private

    def display_template_body_line(line)
      placeholder_name = layout_placeholder_line_name(line)
      return line unless placeholder_name

      "[Layout placeholder: #{placeholder_for_line(line)}]\n"
    end

    def layout_placeholder_line_name(line)
      stripped = line.to_s.strip
      legacy_placeholder_name(stripped) || liquid_placeholder_name(stripped)
    end

    def legacy_placeholder_name(stripped)
      name = stripped.match(/\A%[<{]([a-zA-Z_]\w*)[>}]s?\z/)&.captures&.first
      LAYOUT_PLACEHOLDER_NAMES.include?(name) ? name : nil
    end

    def liquid_placeholder_name(stripped)
      name = stripped.match(/\A\{\{-?\s*([a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*)\s*-?\}\}\z/)&.captures&.first
      LAYOUT_PLACEHOLDER_NAMES.include?(name) ? name : nil
    end

    def placeholder_for_line(line)
      line.to_s.strip
    end

    def admin_actionable_template_error?(message)
      message.include?('Use variables from Insert Variable only') ||
        message.include?('Liquid templates can only use Required Variables') ||
        message.include?('still has standard placeholders') ||
        message.include?('only available for text templates')
    end

    def template_placeholder_error?(message)
      message.match?(/Liquid|placeholder|syntax|variable|required|render/i)
    end

    def invalid_liquid_syntax_error?(message)
      message.match?(/Invalid Liquid syntax|Liquid syntax error/i)
    end
  end
end
