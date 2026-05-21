# frozen_string_literal: true

module PasswordFieldHelper
  def password_visibility_data(timeout: 5000)
    {
      controller: 'visibility',
      visibility_timeout_value: timeout,
      visibility_hidden_status_value: t('password_visibility.status.hidden'),
      visibility_visible_status_value: t('password_visibility.status.visible'),
      visibility_show_label_value: t('password_visibility.toggle.show'),
      visibility_hide_label_value: t('password_visibility.toggle.hide')
    }
  end

  # Creates a password field with a visibility toggle button using Rails form helpers.
  #
  # @param form [::ActionView::Helpers::FormBuilder] the form builder object
  # @param field_name [Symbol, String] the name of the password field
  # @param options [Hash] Options for customizing the password field
  # @option options [String] :label Custom label text
  # @option options [String] :placeholder Placeholder text
  # @option options [Boolean] :required Whether the field is required
  # @option options [String] :autocomplete Autocomplete attribute value
  # @option options [Integer] :timeout Timeout in milliseconds before hiding password again
  # @option options [String] :hint Hint text to display below the field
  # @option options [Hash] :html_options Additional HTML options for the password field
  # @return [::ActiveSupport::SafeBuffer] HTML for the password field with visibility toggle
  def password_field_with_toggle(form, field_name, options = {})
    config = extract_password_field_config(form, field_name, options)
    field_options = build_field_options(config, field_name)

    html_segments = []
    html_segments << '<div class="space-y-1">'.html_safe
    html_segments << form.label(field_name, config[:label], class: 'block text-sm font-medium text-gray-700')
    html_segments << build_field_container(form, field_name, field_options, config)
    html_segments << (config[:hint] ? "<p class=\"text-xs text-gray-500\" id=\"#{config[:field_id]}-hint\">#{config[:hint]}</p>" : '').html_safe
    html_segments << '</div>'.html_safe

    safe_join(html_segments)
  end

  private

  # Extract configuration values from the given options.
  #
  # @param form [::ActionView::Helpers::FormBuilder]
  # @param field_name [Symbol, String]
  # @param options [Hash]
  # @return [Hash] configuration options for the field
  def extract_password_field_config(form, field_name, options)
    field_id = options[:id] || "#{form.object_name}_#{field_name}"
    {
      label: options.delete(:label) || field_name.to_s.humanize,
      placeholder: options.delete(:placeholder),
      required: options.delete(:required) != false,
      autocomplete: options.delete(:autocomplete) || (field_name.to_s.include?('confirmation') ? 'new-password' : 'current-password'),
      timeout: options.delete(:timeout) || 5000,
      hint: options.delete(:hint),
      html_options: options.delete(:html_options) || {},
      field_id: field_id,
      status_id: "#{field_id}_visibility_status",
      base_classes: 'mt-1 block w-full px-4 py-2 pr-12 bg-white border border-gray-300 rounded-md ' \
                    'focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500 sm:text-sm'
    }
  end

  # Build the CSS classes for the password field input.
  #
  # @param base_classes [String]
  # @param html_options [Hash]
  # @return [String] the complete CSS class string
  def build_password_field_classes(base_classes, html_options)
    html_options[:class] ? "#{base_classes} #{html_options[:class]}" : base_classes
  end

  # Prepare the field options for the password field.
  #
  # @param config [Hash]
  # @param field_name [Symbol, String]
  # @return [Hash] the options passed to form.password_field
  def build_field_options(config, field_name)
    html_options = config[:html_options]
    # Add minlength if it's a password field and not already specified
    html_options[:minlength] = 6 if field_name.to_s.include?('password') && !html_options.key?(:minlength)

    field_options = {
      class: build_password_field_classes(config[:base_classes], html_options),
      required: config[:required],
      autocomplete: config[:autocomplete],
      data: {
        visibility_target: field_name.to_s.include?('confirmation') ? 'fieldConfirmation' : 'field'
      },
      aria: {
        describedby: config[:status_id]
      }
    }
    field_options[:placeholder] = config[:placeholder] if config[:placeholder].present?
    field_options.merge(html_options)
  end

  # Build the container for the password field and toggle button.
  #
  # @param form [::ActionView::Helpers::FormBuilder]
  # @param field_name [Symbol, String]
  # @param field_options [Hash]
  # @param config [Hash]
  # @return [::ActiveSupport::SafeBuffer] the HTML for the field container
  def build_field_container(form, field_name, field_options, config)
    content_tag(:div, class: 'relative', data: password_visibility_data(timeout: config[:timeout])) do
      safe_join([
                  form.password_field(field_name, field_options),
                  build_toggle_button,
                  content_tag(:div, t('password_visibility.status.hidden'),
                              id: config[:status_id],
                              class: 'sr-only',
                              aria: { live: 'polite' },
                              data: { visibility_target: 'status' })
                ])
    end
  end

  # Build the HTML for the toggle button.
  #
  # @return [::ActiveSupport::SafeBuffer] the HTML for the toggle button
  def build_toggle_button
    content_tag(:button,
                type: 'button',
                class: password_visibility_button_classes,
                data: { action: 'visibility#togglePassword' },
                aria: { label: t('password_visibility.toggle.show'), pressed: 'false' }) do
      tag.svg(
        class: 'h-5 w-5',
        data: { visibility_target: 'icon' },
        fill: 'none',
        viewBox: '0 0 24 24',
        stroke: 'currentColor',
        aria: { hidden: 'true' }
      ) do
        safe_join([
                    tag.path(d: 'M15 12a3 3 0 11-6 0 3 3 0 016 0z'),
                    tag.path(d: 'M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z')
                  ])
      end
    end
  end

  def password_visibility_button_classes
    [
      'absolute inset-y-0 right-0 flex items-center pr-3',
      'text-gray-400 hover:text-gray-500',
      'focus:outline-none focus:ring-2 focus:ring-indigo-500',
      'eye-closed'
    ].join(' ')
  end
end
