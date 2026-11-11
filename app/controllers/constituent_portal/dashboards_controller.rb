# frozen_string_literal: true

module ConstituentPortal
  class DashboardsController < ApplicationController
    include ViewerLocale

    around_action :with_viewer_locale

    # The shared scope preloads users and their guardian relationships for managed applications.
    include ApplicationDataLoading

    before_action :authenticate_user!
    before_action :require_constituent!
    before_action :load_applications, only: [:show]
    helper_method :get_latest_rejection_reason, :get_latest_rejection_date

    def show
      set_active_and_draft_applications
      load_voucher_information
      load_training_sessions_information
      load_relationship_and_proof_summaries
      load_recent_activities
      @recent_purchases = VoucherTransaction.purchases_visible_to(current_user).limit(5)
    end

    protected

    def get_latest_rejection_reason(application, proof_type)
      latest_review = latest_rejected_review(application, proof_type)
      latest_review&.notes || latest_review&.rejection_reason
    end

    def get_latest_rejection_date(application, proof_type)
      latest_rejected_review(application, proof_type)&.reviewed_at
    end

    def latest_rejected_review(application, proof_type)
      @latest_rejected_reviews[[application.id, proof_type.to_s]]
    end

    private

    def load_applications
      # Drafts have separate continuation links.
      @applications = current_user.applications.accessible_by(current_user)
                                  .where.not(status: :draft).order(created_at: :desc)

      # The shared scope excludes draft, rejected, and archived applications.
      @managed_applications = build_application_base_scope
                              .where(managing_guardian_id: current_user.id)
                              .order(created_at: :desc)

      @managed_drafts = Application.where(managing_guardian_id: current_user.id, status: :draft)
                                   .order(created_at: :desc)

      Rails.logger.info "Dashboard loaded guardian applications for user #{current_user.id}: " \
                        "#{@managed_applications.count} managed applications, " \
                        "#{@managed_drafts.count} managed drafts"
    end

    def set_active_and_draft_applications
      @active_application = @applications.first

      @draft_application = current_user.applications.accessible_by(current_user)
                                       .where(status: :draft).order(:id).first

      @active_managed_application = @managed_applications.first

      @primary_active_application = @active_application || @active_managed_application

      Rails.logger.info "Dashboard loaded for user #{current_user.id}: " \
                        "#{@applications.count} submitted applications, " \
                        "active_application_id=#{@active_application&.id}, " \
                        "draft_application_id=#{@draft_application&.id}, " \
                        "primary_active_application_id=#{@primary_active_application&.id}"
    end

    def load_voucher_information
      @voucher = (@active_application.vouchers.available.first if @active_application)

      @remaining_service_months = calculate_remaining_service_months
    end

    def load_training_sessions_information
      return unless @active_application

      @max_training_sessions = Policy.max_training_sessions

      all_sessions = @active_application.training_sessions
      @completed_training_sessions = all_sessions.completed_sessions
                                                 .where(application: Application.accessible_by(current_user))
                                                 .includes(:trainer, :product_trained_on)
                                                 .order(completed_at: :desc, id: :desc)
      @completed_training_sessions_count = @completed_training_sessions.count
      @active_training_session           = @active_application.active_training_session

      @remaining_training_sessions = @active_application.remaining_training_sessions
    end

    def load_recent_activities
      @recent_activities = get_recent_activities(@active_application) if @active_application
    end

    def load_relationship_and_proof_summaries
      ActiveRecord::Associations::Preloader.new(
        records: [current_user], associations: [
          { guardian_relationships_as_guardian: :dependent_user },
          { guardian_relationships_as_dependent: :guardian_user }
        ]
      ).call
      @dependent_relationships = current_user.guardian_relationships_as_guardian.index_by(&:dependent_id)
      @guardian_relationships = current_user.guardian_relationships_as_dependent.index_by(&:guardian_id)
      @dependents = @dependent_relationships.values.map(&:dependent_user)
      @guardians = @guardian_relationships.values.map(&:guardian_user)
      @managed_by_applicant = @managed_applications.to_a.group_by(&:user_id).transform_values(&:first)
      @drafts_by_applicant = @managed_drafts.to_a.group_by(&:user_id).transform_values(&:first)
      ids = [@active_application&.id, *@managed_applications.map(&:id)].compact.uniq
      @latest_rejected_reviews = ProofReview.where(application_id: ids, status: :rejected)
                                            .chronological.index_by { |review| [review.application_id, review.proof_type] }
    end

    def get_recent_activities(application)
      ConstituentPortal::Activity.from_events(application).last(10)
    end

    def calculate_remaining_service_months
      end_date = @active_application&.service_window_end_date
      return nil unless end_date

      months_remaining = ((end_date.year - Time.current.year) * 12) + (end_date.month - Time.current.month)

      [months_remaining, 0].max
    end
  end
end
