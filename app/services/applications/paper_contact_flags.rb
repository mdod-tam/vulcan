# frozen_string_literal: true

module Applications
  # Normalizes explicit paper-intake "no contact" choices before user creation/update.
  class PaperContactFlags
    FLAG_KEYS = {
      constituent: {
        email: :no_email_address,
        phone: :no_phone_number
      },
      guardian: {
        email: :guardian_no_email_address,
        phone: :guardian_no_phone_number
      }
    }.freeze

    attr_reader :params, :scope

    def initialize(params, scope:)
      @params = hash_for(params).with_indifferent_access
      @scope = scope.to_sym
    end

    def apply_to(attrs)
      data = hash_for(attrs).deep_dup.with_indifferent_access

      if no_email?
        data.delete(:email)
        data[:communication_preference] = 'letter'
      end

      if no_phone?
        data.delete(:phone)
        data[:phone_type] = preferred_contact_method_without_phone(data)
        data[:communication_preference] = 'letter' if data[:email].blank?
      end

      data[:communication_preference] = 'letter' if data[:email].blank? && data[:phone].blank?

      data
    end

    def apply_clear_flags_to(updates)
      data = hash_for(updates).with_indifferent_access

      if no_email?
        data[:email] = nil
        data[:communication_preference] = 'letter'
      end

      if no_phone?
        data[:phone] = nil
        data[:phone_type] = preferred_contact_method_without_phone(data)
      end

      data[:communication_preference] = 'letter' if no_email? && no_phone?

      data
    end

    def skip_email_validation?
      no_email?
    end

    def skip_phone_validation?
      no_phone?
    end

    def no_email?
      truthy_param?(flag_key(:email))
    end

    def no_phone?
      truthy_param?(flag_key(:phone))
    end

    private

    def hash_for(value)
      return value.to_unsafe_h if value.respond_to?(:to_unsafe_h)

      value.to_h
    end

    def flag_key(contact_type)
      FLAG_KEYS.fetch(scope).fetch(contact_type)
    end

    def truthy_param?(key)
      params[key].present? && params[key].to_s == '1'
    end

    def preferred_contact_method_without_phone(data)
      data[:email].present? ? 'email' : 'letter'
    end
  end
end
