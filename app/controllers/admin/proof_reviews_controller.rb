# frozen_string_literal: true

module Admin
  class ProofReviewsController < ApplicationController
    # ApplicationDataLoading concern: Provides optimized methods for loading applications and attachments
    # Key benefits: Preloads attachment metadata, avoids N+1 queries, optimizes for proof review workflows
    include ApplicationDataLoading

    before_action :authenticate_user!
    before_action :require_admin!
    before_action :set_application
    before_action :set_proof_review, only: %i[show]
    before_action :ensure_reviewable_status, only: %i[new create]

    def index
      @proof_reviews = @application.proof_reviews.includes(:admin).order(created_at: :desc)
    end

    def show
      @proof = case @proof_review.proof_type
               when 'income'
                 @application.income_proof
               when 'residency'
                 @application.residency_proof
               end

      return if @proof&.attached?

      redirect_to admin_application_path(@application), alert: 'Proof file no longer available'
    end

    def new
      @proof_review = @application.proof_reviews.build
      @proof_type = params[:proof_type]

      @proof = case @proof_type
               when 'income'
                 @application.income_proof
               when 'residency'
                 @application.residency_proof
               end

      return if @proof.attached? || @proof.nil?

      redirect_to admin_application_path(@application), alert: "#{@proof_type.titleize} proof file is missing"
    end

    def create
      @proof_review = @application.proof_reviews.build(proof_review_params)
      @proof_review.admin = current_user

      if @proof_review.save
        redirect_to admin_application_path(@application), notice: 'Proof review completed successfully'
      else
        render :new, status: :unprocessable_content, alert: 'Proof review failed to save'
      end
    end

    private

    def set_application
      # ApplicationDataLoading concern: Uses optimized application loading with attachment preloading
      # Flow: load_application_with_attachments -> finds application + preloads proof attachments
      # This is crucial for proof review since we need attachment metadata without N+1 queries
      @application = load_application_with_attachments(params[:application_id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_applications_path, alert: 'Application not found'
    end

    def set_proof_review
      @proof_review = @application.proof_reviews.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      redirect_to admin_application_path(@application), alert: 'Review not found'
    end

    def proof_review_params
      params.expect(proof_review: %i[proof_type status rejection_reason])
    end

    def next_proof_for_review
      return 'residency' if params[:proof_type] == 'income' &&
                            @application.residency_proof.attached? &&
                            @application.residency_proof_status_not_reviewed?

      return 'income' if params[:proof_type] == 'residency' &&
                         @application.income_proof.attached? &&
                         @application.income_proof_status_not_reviewed?

      nil
    end

    def require_admin!
      return if current_user&.admin?

      flash[:alert] = 'You are not authorized to perform this action'
      redirect_to root_path
    end

    def ensure_reviewable_status
      return if @application.proofs_reviewable?

      redirect_to admin_application_path(@application), alert: 'Application is not in a reviewable state'
    end
  end
end
