# frozen_string_literal: true

module MailerPartAssertions
  def decoded_text_part(email)
    (email.text_part || email).body.decoded
  end

  # Mailer params for the notice announcing a training session or evaluation's current assignment operation.
  def assignment_notice_params(assignment, recipient)
    { (assignment.is_a?(Evaluation) ? :evaluation : :assignment) => assignment, recipient: recipient,
      operation_id: assignment.assignment_operation_id }
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include MailerPartAssertions
end
