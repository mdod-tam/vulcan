# frozen_string_literal: true

module Variables
  class ProofRejected
    include Mailers::ApplicationNotificationsHelper

      def initialize(application, proof_review, remaining_attempts:, reapply_date:,
                     base_variables:, sign_in_url:)
        @application        = application
        @proof_review       = proof_review
        @remaining_attempts = remaining_attempts
        @reapply_date       = reapply_date
        @base_variables     = base_variables
        @sign_in_url        = sign_in_url
      end

      def to_h
        @base_variables
          .merge(proof_variables)
          .merge(conditional_variables)
          .compact
      end

      private

      def proof_variables
        user = @application.user
        {
          user_first_name: user.first_name,
          constituent_full_name: user.full_name,
          organization_name: 'MAT Program',
          proof_type_formatted: format_proof_type(@proof_review.proof_type),
          rejection_reason: resolve_rejection_reason(user.locale.presence || 'en'),
          additional_instructions: @proof_review.notes,
          sign_in_url: @sign_in_url
        }
      end

      def conditional_variables
        if @remaining_attempts.positive?
          {
            remaining_attempts_message_text: remaining_attempts_message,
            default_options_text: default_options_text,
            archived_message_text: ''
          }
        else
          {
            remaining_attempts_message_text: '',
            default_options_text: '',
            archived_message_text: archived_message
          }
        end
      end

      def resolve_rejection_reason(locale)
        return @proof_review.rejection_reason if @proof_review.rejection_reason_code.blank?

        reason = RejectionReason.resolve(
          code: @proof_review.rejection_reason_code,
          proof_type: @proof_review.proof_type,
          locale: locale
        )
        return @proof_review.rejection_reason unless reason&.body

        interpolate_address_placeholder(reason.body)
      end

      def interpolate_address_placeholder(body)
        return body unless body.include?('%{address}') || body.include?('%<address>')

        body % { address: application_address }
      rescue KeyError, ArgumentError
        body
      end

      def application_address
        user = @application.user
        return '' unless user

        addr1 = user.physical_address_1.to_s
        addr2 = user.physical_address_2.presence || ''
        city = user.city.to_s
        state = user.state.to_s
        zip = user.zip_code.to_s
        "#{addr1} #{addr2} #{city}, #{state} #{zip}".squish
      end

      def remaining_attempts_message
        "You have #{@remaining_attempts} #{'attempt'.pluralize(@remaining_attempts)} remaining to
    submit the required documentation before #{@reapply_date.strftime('%B %d, %Y')}."
      end

      def default_options_text
        <<~TEXT.strip
          HOW TO RESUBMIT YOUR DOCUMENTATION:
          1. Reply to this email: Simply reply to this email and attach your updated documentation.
          2. Upload Online: Sign in to your account dashboard at #{@sign_in_url} and upload your new documents securely.
          3. Mail it to us: You can mail copies of your documents to our office, and we will scan and upload them for you:
             Maryland Accessible Telecommunications
             123 Main Street
             Baltimore, MD 21201
        TEXT
      end

      def archived_message
        "Unfortunately, you have reached the maximum number of submission attempts. Your application has been archived.
    You may reapply after #{@reapply_date.strftime('%B %d, %Y')}."
      end
  end
end
