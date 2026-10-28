# frozen_string_literal: true

# Maps a submission method to one of VALID_METHODS, and anything else to :unknown.
class SubmissionMethodValidator
  # :secure_form records proof and certification submissions from secure request links.
  VALID_METHODS = %i[paper web email secure_form unknown].freeze

  def self.validate(submission_method)
    candidate = submission_method.to_s.to_sym
    return candidate if VALID_METHODS.include?(candidate)

    Rails.logger.warn("Invalid submission_method '#{submission_method}' - defaulting to :unknown")
    :unknown
  end
end
