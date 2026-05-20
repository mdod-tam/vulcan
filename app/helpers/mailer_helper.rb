# frozen_string_literal: true

module MailerHelper
  # Get the color values for a status box
  # @param status [Symbol] The status (:success, :warning, :error, :info)
  # @return [Hash] The color values for the status
  def status_box_colors(status)
    colors = {
      success: {
        bg: '#ebf8ff',      # Light blue background
        border: '#90cdf4',  # Medium blue border
        text: '#2b6cb0',    # Dark blue text
        icon: '✓'           # Success icon
      },
      warning: {
        bg: '#fffaf0',      # Light orange background
        border: '#fbd38d',  # Medium orange border
        text: '#c05621',    # Dark orange text
        icon: '⚠'           # Warning icon
      },
      error: {
        bg: '#fff5f5',      # Light red background
        border: '#feb2b2',  # Medium red border
        text: '#c53030',    # Dark red text
        icon: '✗'           # Error icon
      },
      info: {
        bg: '#ebf4ff',      # Light blue background
        border: '#c3dafe',  # Medium blue border
        text: '#434190',    # Dark blue text
        icon: 'ℹ'           # Info icon
      }
    }

    status = status.to_sym if status.respond_to?(:to_sym)
    colors[status] || colors[:info]
  end

  # Format a date consistently across all mailers
  # @param date [Date, Time, DateTime, String] The date to format
  # @param format [Symbol] The format to use (:short, :long, :full)
  # @return [String] The formatted date
  def format_date(date, format = :long)
    return '' if date.nil?

    date = parse_date(date)
    return date.to_s unless date.respond_to?(:strftime)

    format_date_str(date, format)
  end

  # Format a currency value consistently across all mailers
  # @param amount [Numeric] The amount to format
  # @param precision [Integer] The number of decimal places
  # @return [String] The formatted currency
  def format_currency(amount, precision = 2)
    number_to_currency(amount, precision: precision)
  end

  # Format a phone number consistently across all mailers
  # @param phone [String] The phone number to format
  # @return [String] The formatted phone number
  def format_phone(phone)
    return '' if phone.blank?

    # Remove all non-numeric characters
    digits = phone.to_s.gsub(/\D/, '')

    # Format based on length
    case digits.length
    when 10
      "(#{digits[0..2]}) #{digits[3..5]}-#{digits[6..9]}"
    when 11
      if digits[0] == '1'
        "+1 (#{digits[1..3]}) #{digits[4..6]}-#{digits[7..10]}"
      else
        digits
      end
    else
      phone # Return original if we can't format it
    end
  end

  # Format an address consistently across all mailers
  # @param address1 [String] Address line 1
  # @param address2 [String] Address line 2 (optional)
  # @param city [String] City
  # @param state [String] State
  # @param zip [String] ZIP code
  # @return [String] The formatted address
  def format_address(address1, address2, city, state, zip)
    address = address1.to_s
    address += "<br>#{address2}" if address2.present?
    address += "<br>#{city}, #{state} #{zip}"
    address.html_safe
  end

  # Format an address for plain text emails
  # @param address1 [String] Address line 1
  # @param address2 [String] Address line 2 (optional)
  # @param city [String] City
  # @param state [String] State
  # @param zip [String] ZIP code
  # @return [String] The formatted address
  def format_text_address(address1, address2, city, state, zip)
    address = address1.to_s
    address += "\n#{address2}" if address2.present?
    address += "\n#{city}, #{state} #{zip}"
    address
  end

  # Format a proof type consistently across all mailers
  # @param proof_type [String, Symbol, Integer] The proof type
  # @return [String] The formatted proof type
  def format_proof_type(proof_type)
    return '' if proof_type.nil?

    # If it's a ProofReview instance, get the proof_type before type cast
    type_value = if proof_type.respond_to?(:proof_type_before_type_cast)
                   proof_type.proof_type_before_type_cast
                 else
                   proof_type
                 end

    # Convert to string and handle both symbol and integer cases
    normalized_type = case type_value.to_s
                      when '0', 'income'
                        'income'
                      when '1', 'residency'
                        'residency'
                      when '3', 'id'
                        'id'
                      else
                        type_value.to_s
                      end

    I18n.t(
      "secure_proof_forms.proof_types.#{normalized_type}",
      default: normalized_type.humanize.downcase
    )
  end

  # Returns the appropriate text for training session scheduling information
  # based on whether a session has been scheduled or not
  # @param training_session [TrainingSession] The training session
  # @return [String] The formatted scheduling information text
  def training_session_schedule_text(training_session)
    if training_session.scheduled_for.present?
      "A training session has been tentatively scheduled for #{format_date(training_session.scheduled_for,
                                                                           :full)}, but you may reschedule this with the constituent as needed."
    else
      'Please contact the constituent to schedule a training session at a mutually convenient time.'
    end
  end

  # Parses a date string into a Date or Time object if possible.
  # @param [Date, Time, DateTime, String] date the date or date string to parse
  # @return [Date, Time, DateTime, String] the parsed date or the original value if parsing fails
  def parse_date(date)
    return date unless date.is_a?(String)

    begin
      date.include?(':') ? Time.zone.parse(date) : Date.parse(date)
    rescue ArgumentError, TypeError
      date
    end
  end

  # Formats a date using strftime based on the provided format.
  #
  # @param [Date, Time, DateTime] date the date object to format
  # @param [Symbol] format the format type (:short, :long, :full)
  # @return [String] the formatted date string
  def format_date_str(date, format)
    case format
    when :short
      date.strftime('%m/%d/%Y')
    when :full
      date.strftime('%B %d %Y at %I:%M %p')
    else
      date.strftime('%B %d %Y')
    end
  rescue StandardError => e
    Rails.logger.error("Error formatting date: #{e.message} for date: #{date.inspect}")
    date.to_s
  end
end
