# frozen_string_literal: true

require 'liquid'

module EmailTemplates
  class Renderer
    LEGACY_SYNTAX = 'legacy_percent'
    LIQUID_SYNTAX = 'liquid'
    SYNTAXES = [LEGACY_SYNTAX, LIQUID_SYNTAX].freeze

    LEGACY_PLACEHOLDER_PATTERN = /%[<{]([a-zA-Z_]\w*)[>}]s?/
    LIQUID_TAG_PATTERN = /\{%-?.*?-?%\}/m
    LIQUID_OUTPUT_PATTERN = /\{\{-?(.*?)-?\}\}/m
    LIQUID_PATH_PATTERN = /\A[a-zA-Z_]\w*(?:\.[a-zA-Z_]\w*)*\z/
    MISSING = Object.new.freeze

    attr_reader :template, :variables

    def self.render(template:, variables:)
      new(template: template, variables: variables).render
    end

    def self.render_text(template:, text:, variables:)
      new(template: template, variables: variables).render_text(text)
    end

    def self.extract_variables(subject:, body:, syntax:)
      texts = [subject, body]

      case syntax.to_s
      when LIQUID_SYNTAX
        texts.flat_map { |text| extract_liquid_variables(text) }.uniq
      else
        texts.flat_map { |text| extract_legacy_variables(text) }.uniq
      end
    end

    def self.validate_template_syntax!(subject:, body:, syntax:)
      return unless syntax.to_s == LIQUID_SYNTAX

      [subject, body].each { |text| validate_liquid_text!(text) }
    end

    def self.extract_legacy_variables(text)
      text.to_s.scan(LEGACY_PLACEHOLDER_PATTERN).flatten.uniq
    end

    def self.extract_liquid_variables(text)
      validate_liquid_text!(text)
      text.to_s.scan(LIQUID_OUTPUT_PATTERN).map { |match| normalize_liquid_output(match.first) }.uniq
    end

    def self.validate_liquid_text!(text)
      source = text.to_s

      if source.match?(LIQUID_TAG_PATTERN)
        raise ArgumentError,
              'Only simple variable placeholders like {{ name }} are supported. Remove Liquid tags such as {% if %}.'
      end

      source.scan(LIQUID_OUTPUT_PATTERN).each do |match|
        normalize_liquid_output(match.first)
      end

      Liquid::Template.parse(source, error_mode: :strict)
    rescue Liquid::Error => e
      raise ArgumentError, "Invalid Liquid syntax: #{e.message}"
    end

    def self.normalize_liquid_output(raw_output)
      output = raw_output.to_s.strip
      output = output.delete_prefix('-').delete_suffix('-').strip

      if output.include?('|')
        raise ArgumentError,
              'Only simple variable placeholders like {{ name }} are supported. Remove filters such as | upcase.'
      end
      unless output.match?(LIQUID_PATH_PATTERN)
        variable_name = output.empty? ? 'This placeholder' : output
        raise ArgumentError, "Use variables from Insert Variable only. #{variable_name} is not available for this template."
      end

      output
    end

    def initialize(template:, variables:)
      @template = template
      @variables = variables.to_h
    end

    def render
      validate_format!
      validate_feature_flag!
      validate_template_syntax!
      validate_allowed_variables!
      validate_required_variables!

      case syntax
      when LIQUID_SYNTAX
        render_liquid
      else
        render_legacy
      end
    end

    def render_text(text)
      validate_format!
      validate_feature_flag!
      validate_template_syntax!(subject: text, body: nil)
      used_variables = extracted_variables_for(subject: text, body: nil)
      validate_allowed_variables!(used_variables)
      validate_present_variables!(used_variables) if syntax == LIQUID_SYNTAX

      case syntax
      when LIQUID_SYNTAX
        render_liquid_text(text, liquid_assigns(paths: used_variables))
      else
        render_legacy_text(text)
      end
    end

    private

    def syntax
      template.respond_to?(:render_syntax) ? template.render_syntax : template.syntax.to_s
    end

    def validate_format!
      return unless syntax == LIQUID_SYNTAX
      return if template.respond_to?(:text?) && template.text?

      raise ArgumentError, 'Liquid email template rendering is only available for text templates'
    end

    def validate_feature_flag!
      return unless syntax == LIQUID_SYNTAX
      return if FeatureFlag.enabled?(:email_template_liquid)

      raise ArgumentError, 'Liquid templates are not enabled yet. Contact your administrator.'
    end

    def validate_template_syntax!(subject: template.subject, body: template.body)
      self.class.validate_template_syntax!(subject: subject, body: body, syntax: syntax)
    end

    def validate_allowed_variables!(variables_to_validate = extracted_variables)
      unauthorized = variables_to_validate - allowed_paths
      return if unauthorized.empty?

      raise ArgumentError, unavailable_variables_message(unauthorized)
    end

    def validate_required_variables!
      validate_present_variables!(template.required_variables)
    end

    def validate_present_variables!(paths)
      missing_vars = paths.reject { |path| value_available?(path) }
      return if missing_vars.empty?

      raise ArgumentError, "Missing required variables for template '#{template.name}': #{missing_vars.join(', ')}"
    end

    def extracted_variables
      @extracted_variables ||= extracted_variables_for(subject: template.subject, body: template.body)
    end

    def extracted_variables_for(subject:, body:)
      self.class.extract_variables(subject: subject, body: body, syntax: syntax)
    end

    def render_legacy
      [
        render_legacy_text(template.subject),
        render_legacy_text(template.body)
      ]
    end

    def render_legacy_text(text)
      rendered_text = text.to_s.dup

      variables.each do |key, value|
        key = key.to_s
        rendered_text = rendered_text.gsub("%{#{key}}", value.to_s)
        rendered_text = rendered_text.gsub("%<#{key}>s", value.to_s)
        rendered_text = rendered_text.gsub("%<#{key}>", value.to_s)
      end

      rendered_text.gsub(LEGACY_PLACEHOLDER_PATTERN, '')
    end

    def render_liquid
      assigns = liquid_assigns

      [
        render_liquid_text(template.subject, assigns),
        render_liquid_text(template.body, assigns)
      ]
    end

    def render_liquid_text(text, assigns)
      Liquid::Template
        .parse(text.to_s, error_mode: :strict)
        .render!(assigns, strict_variables: true, strict_filters: true)
    rescue Liquid::Error => e
      raise ArgumentError, "Liquid render failed for template '#{template.name}': #{e.message}"
    end

    def unavailable_variables_message(variable_names)
      names = variable_names.join(', ')
      verb = variable_names.one? ? 'is' : 'are'
      "Use variables from Insert Variable only. #{names} #{verb} not available for this template."
    end

    def liquid_assigns(paths: allowed_paths)
      paths.each_with_object({}) do |path, assigns|
        value = value_at_path(path)
        next if value.equal?(MISSING)

        assign_liquid_path(assigns, path, value)
      end
    end

    def allowed_paths
      syntax == LIQUID_SYNTAX ? template.required_variables : template.allowed_variables
    end

    def value_available?(path)
      !value_at_path(path).equal?(MISSING)
    end

    def value_at_path(path)
      string_path = path.to_s
      return variables[string_path] if variables.key?(string_path)
      return variables[string_path.to_sym] if variables.key?(string_path.to_sym)

      segments = string_path.split('.')
      value = fetch_segment(variables, segments.shift)
      return MISSING if value.equal?(MISSING)

      segments.each do |segment|
        value = fetch_segment(value, segment)
        return MISSING if value.equal?(MISSING)
      end

      value
    end

    def fetch_segment(value, segment)
      return MISSING unless value.is_a?(Hash)

      return value[segment] if value.key?(segment)
      return value[segment.to_sym] if value.key?(segment.to_sym)

      MISSING
    end

    def assign_liquid_path(assigns, path, value)
      segments = path.to_s.split('.')
      final_segment = segments.pop
      cursor = assigns

      segments.each do |segment|
        cursor[segment] ||= {}
        cursor = cursor[segment]
      end

      cursor[final_segment] = value
    end
  end
end
