# frozen_string_literal: true

# This service validates if a submission method is valid and provides a fallback
# mechanism for when nil or invalid values are provided.
class SubmissionMethodValidator
  # :secure_form was added alongside the Phase 2/3 secure temp form feature to
  # record proof and cert submissions that arrive through tokenized public forms.
  VALID_METHODS = %i[paper web email secure_form unknown].freeze

  # Returns a valid submission method or :unknown as a fallback
  # @param submission_method [Symbol, String, nil] The submission method to validate
  # @return [Symbol] A valid submission method symbol
  def self.validate(submission_method)
    if submission_method.present? && VALID_METHODS.include?(submission_method.to_sym)
      submission_method.to_sym
    else
      Rails.logger.warn("Invalid submission_method '#{submission_method}' - defaulting to :unknown")
      :unknown
    end
  rescue StandardError
    # Handle any errors when trying to convert to symbol
    Rails.logger.warn("Error converting '#{submission_method}' to symbol - defaulting to :unknown")
    :unknown
  end
end
