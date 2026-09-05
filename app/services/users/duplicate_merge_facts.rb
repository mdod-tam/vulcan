# frozen_string_literal: true

module Users
  # Compares the bounded record facts presented by the duplicate merge form.
  #
  # The form collapses a fact only when both records currently store the same normalized value.
  # DuplicateMergeService calls the same owner again after locking both users, so a stale or forged
  # "both records agree" marker cannot become an unreviewed contact or delivery choice.
  class DuplicateMergeFacts
    ADDRESS_FIELDS = %i[physical_address_1 physical_address_2 city state zip_code].freeze
    FACTS = %i[date_of_birth phone phone_type address delivery].freeze

    attr_reader :first_user, :second_user

    def initialize(first_user, second_user)
      @first_user = first_user
      @second_user = second_user
    end

    def agreed?(fact)
      validate_fact!(fact)
      fact_value(first_user, fact) == fact_value(second_user, fact)
    end

    def agreed_value(fact)
      raise ArgumentError, "#{fact} does not agree" unless agreed?(fact)

      fact_value(first_user, fact)
    end

    private

    def validate_fact!(fact)
      return if FACTS.include?(fact.to_sym)

      raise ArgumentError, "Unsupported duplicate merge fact: #{fact}"
    end

    def fact_value(user, fact)
      case fact.to_sym
      when :date_of_birth then user.date_of_birth
      when :phone then normalized_string(user.phone)
      when :phone_type then normalized_string(user.phone_type)
      when :address then ADDRESS_FIELDS.map { |field| normalized_string(user.public_send(field)) }
      when :delivery then normalized_string(user.communication_preference)
      end
    end

    def normalized_string(value)
      value.to_s.strip.presence
    end
  end
end
