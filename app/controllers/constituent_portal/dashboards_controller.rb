# frozen_string_literal: true

module ConstituentPortal
  class DashboardsController < ApplicationController
    # The shared scope preloads users and their guardian relationships for managed applications.
    include ApplicationDataLoading

    before_action :authenticate_user!
    before_action :require_constituent!
    before_action :load_applications, only: [:show]
    helper_method :get_latest_rejection_reason, :get_latest_rejection_date, :can_resubmit_proof?

    def show
      set_active_and_draft_applications
      load_voucher_information
      load_training_sessions_information
      load_proof_status_information
      load_recent_activities
      @recent_purchases = VoucherTransaction.purchases_visible_to(current_user).limit(5)
    end

    protected

    def get_latest_rejection_reason(application, proof_type)
      latest_review = application.proof_reviews.where(proof_type: proof_type, status: :rejected)
                                 .order(created_at: :desc).first
      latest_review&.notes || latest_review&.rejection_reason
    end

    def get_latest_rejection_date(application, proof_type)
      latest_review = application.proof_reviews.where(proof_type: proof_type, status: :rejected)
                                 .order(created_at: :desc).first
      latest_review&.created_at
    end

    def can_resubmit_proof?(application, proof_type, max_submissions)
      status_method = "#{proof_type}_proof_status_rejected?"
      return false unless application.send(status_method)

      submission_count = count_proof_submissions(application, proof_type)
      submission_count < max_submissions
    end

    private

    def require_constituent!
      return if current_user&.constituent?

      redirect_to root_path, alert: 'Access denied'
    end

    def load_applications
      # Drafts have separate continuation links.
      @applications = current_user.applications.where.not(status: :draft).order(created_at: :desc)

      if @applications.empty?
        Rails.logger.info "No applications found via association for user #{current_user.id}, trying direct query"
        @applications = Application.where(user_id: current_user.id).where.not(status: :draft).order(created_at: :desc)
      end

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

      @draft_application = current_user.applications.where(status: :draft).first

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

      @waiting_period_months = calculate_waiting_period_months
    end

    def load_training_sessions_information
      return unless @active_application

      @max_training_sessions = Policy.max_training_sessions

      all_sessions = @active_application.training_sessions
      @completed_training_sessions       = all_sessions.completed_sessions
                                                          .includes(:trainer, :product_trained_on)
                                                          .order(completed_at: :desc)
      @completed_training_sessions_count = @completed_training_sessions.count
      @active_training_session           = @active_application.active_training_session

      # Display numbers follow completion order. Open sessions reserve quota without numbers in this map.
      @training_session_numbers = all_sessions.completed_sessions.order(completed_at: :asc, created_at: :asc)
                                              .pluck(:id)
                                              .each_with_index
                                              .to_h { |id, i| [id, i + 1] }

      @remaining_training_sessions = @active_application.remaining_training_sessions
    end

    def load_proof_status_information
      return unless @active_application

      @max_proof_submissions = Policy.get('max_proof_submissions') || 3
      load_income_proof_information
      load_residency_proof_information
      load_id_proof_information
    end

    def load_income_proof_information
      @income_proof_status = @active_application.income_proof_status
      @income_proof_rejection_reason = get_latest_rejection_reason(@active_application, 'income')
      @income_proof_rejection_date = get_latest_rejection_date(@active_application, 'income')
      @income_proof_submission_count = count_proof_submissions(@active_application, 'income')
      @can_resubmit_income_proof = can_resubmit_proof?(@active_application, 'income', @max_proof_submissions)
    end

    def load_residency_proof_information
      @residency_proof_status = @active_application.residency_proof_status
      @residency_proof_rejection_reason = get_latest_rejection_reason(@active_application, 'residency')
      @residency_proof_rejection_date = get_latest_rejection_date(@active_application, 'residency')
      @residency_proof_submission_count = count_proof_submissions(@active_application, 'residency')
      @can_resubmit_residency_proof = can_resubmit_proof?(@active_application, 'residency', @max_proof_submissions)
    end

    def load_id_proof_information
      @id_proof_status = @active_application.id_proof_status
      @id_proof_rejection_reason = get_latest_rejection_reason(@active_application, 'id')
      @id_proof_rejection_date = get_latest_rejection_date(@active_application, 'id')
      @id_proof_submission_count = count_proof_submissions(@active_application, 'id')
      @can_resubmit_id_proof = can_resubmit_proof?(@active_application, 'id', @max_proof_submissions)
    end

    def load_recent_activities
      @recent_activities = get_recent_activities(@active_application) if @active_application
    end

    def count_proof_submissions(application, proof_type)
      application.events.where(action: 'proof_submitted', metadata: { proof_type: proof_type }).count
    end

    def get_recent_activities(application)
      ConstituentPortal::Activity.from_events(application).first(10)
    end

    def calculate_waiting_period_months
      return nil unless @active_application

      waiting_period_years = Policy.get('waiting_period_years') || 3
      waiting_period_end_date = @active_application.application_date + waiting_period_years.years

      months_remaining = ((waiting_period_end_date.year - Time.current.year) * 12) +
                         (waiting_period_end_date.month - Time.current.month)

      [months_remaining, 0].max
    end
  end
end
