# frozen_string_literal: true

module ApplicationDataStructures
  # Represents medical provider contact information
  MedicalProviderInfo = Struct.new(:name, :phone, :fax, :email, keyword_init: true) do
    def present?
      name.present? || phone.present? || fax.present? || email.present?
    end

    def valid?
      name.present? && phone.present? && email.present?
    end

    def valid_phone?
      phone.present? && phone.match?(/\A[\d\-()\s.]+\z/)
    end

    def valid_email?
      email.present? && email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def to_h
      {
        name: name,
        phone: phone,
        fax: fax,
        email: email
      }
    end
  end

  # Represents a physical address
  Address = Struct.new(:physical_address_1, :physical_address_2, :city, :state, :zip_code, keyword_init: true) do
    def full_address
      [physical_address_1, physical_address_2, "#{city}, #{state} #{zip_code}"].compact.join("\n")
    end

    def valid?
      physical_address_1.present? && city.present? && state.present? && zip_code.present?
    end

    def to_h
      {
        physical_address_1: physical_address_1,
        physical_address_2: physical_address_2,
        city: city,
        state: state,
        zip_code: zip_code
      }
    end
  end

  # Represents a result from document attachment operations
  ProofResult = Struct.new(:success, :type, :message, keyword_init: true) do
    def success?
      success == true
    end

    def failure?
      !success?
    end

    def to_h
      {
        success: success,
        type: type,
        message: message
      }
    end
  end
end
