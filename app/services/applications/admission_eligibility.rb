# frozen_string_literal: true

module Applications
  # One admission decision for portal writers, paper intake, and admin views.
  # PaperIdentityReview uses it to decide which dependent matches may be selected; the durable
  # writer asks again after locking and requalifying the selected constituent. The preview is
  # advisory and the writer remains authoritative, but both apply the same blocking-application
  # and waiting-period policy.
  class AdmissionEligibility
    SUBJECT_LABELS = { constituent: 'constituent', dependent: 'dependent' }.freeze

    Result = Struct.new(:reason, :waiting_period_ends_at, keyword_init: true) do
      def eligible? = reason.nil?
      def eligible_after = (waiting_period_ends_at if reason == :waiting_period)
      def waiting_period_active? = waiting_period_ends_at.present? && waiting_period_ends_at > Time.current

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

    def self.call(user, applications: user.applications, excluding: nil, skip_wait_period: false, waiting_period_years: Policy.waiting_period_years)
      new(applications, excluding: excluding, skip_wait_period: skip_wait_period, waiting_period_years: waiting_period_years).call
    end

    # A supplied inventory is authoritative, including when its records are locked by a portal writer.
    def initialize(applications, excluding:, skip_wait_period:, waiting_period_years:)
      @applications = Array(applications).select(&:persisted?).reject { |application| excluding && application.id == excluding.id }
      @skip_wait_period = skip_wait_period
      @waiting_period_years = waiting_period_years
    end

    def call
      approved_date = @applications.select(&:status_approved?).filter_map(&:application_date).max
      result = Result.new(waiting_period_ends_at: approved_date && (approved_date + @waiting_period_years.years))
      result.reason = if @applications.any?(&:blocking_new_submission?)
                        :blocking_application
                      elsif !@skip_wait_period && result.waiting_period_active?
                        :waiting_period
                      end
      result
    end
  end
end
