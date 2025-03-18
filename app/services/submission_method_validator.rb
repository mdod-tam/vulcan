# frozen_string_literal: true

# This service validates if a submission method is valid and provides a fallback
# mechanism for when nil or invalid values are provided.
class SubmissionMethodValidator
  VALID_METHODS = [:paper, :web, :email, :unknown].freeze

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
  rescue 
    # Handle any errors when trying to convert to symbol
    Rails.logger.warn("Error converting '#{submission_method}' to symbol - defaulting to :unknown")
    :unknown
  end
end
