# frozen_string_literal: true

module Applications
  # One paper-domain answer to whether an existing constituent may receive a new application.
  # PaperIdentityReview uses it to decide which dependent matches may be selected; the durable
  # writer asks again after locking and requalifying the selected constituent. The preview is
  # advisory and the writer remains authoritative, but both apply the same blocking-application
  # and waiting-period policy.
  class PaperApplicationEligibility
    SUBJECT_LABELS = { constituent: 'constituent', dependent: 'dependent' }.freeze

    # rubocop:disable Style/RedundantStructKeywordInit -- keyword-only prevents reason/date swaps.
    Result = Struct.new(:reason, :eligible_after, keyword_init: true) do
      def eligible? = reason.nil?

      def refusal_message(subject:)
        label = SUBJECT_LABELS.fetch(subject.to_sym)

        case reason
        when :blocking_application
          "This #{label} already has an active or pending application."
        when :waiting_period
          "Not yet eligible for a new application. Eligible after #{eligible_after.to_date.strftime('%B %d, %Y')}."
        end
      end
    end
    # rubocop:enable Style/RedundantStructKeywordInit

    def self.call(user)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      return Result.new(reason: :blocking_application) if @user.applications.blocking_new_submission.exists?

      last_application = @user.applications.order(application_date: :desc).first
      return Result.new if last_application.blank?

      waiting_period = Policy.get('waiting_period_years') || 3
      eligible_after = last_application.application_date + waiting_period.years
      return Result.new if eligible_after <= Time.current

      Result.new(reason: :waiting_period, eligible_after: eligible_after)
    end
  end
end
