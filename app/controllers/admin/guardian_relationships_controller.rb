# frozen_string_literal: true

module Admin
  class GuardianRelationshipsController < Admin::BaseController
    include UserServiceIntegration

    before_action :set_guardian, only: %i[new create]
    before_action :set_relationship, only: [:destroy]

    def new
      @dependent = User.find_by(id: params[:dependent_id]) if params[:dependent_id].present?
      @guardian_relationship = GuardianRelationship.new(
        guardian_user: @guardian,
        dependent_user: @dependent
      )
    end

    def create
      # Find dependent user
      dependent_user_id = params[:guardian_relationship][:dependent_id]
      dependent_user = User.find_by(id: dependent_user_id)

      unless dependent_user
        flash[:alert] = t(dependent_not_found)
        redirect_to admin_user_path(@guardian)
        return
      end

      # Using UserServiceIntegration concern for consistent relationship creation
      # Flow: create_guardian_relationship_with_service -> handles validation and creation
      if create_guardian_relationship_with_service(@guardian, dependent_user, params[:guardian_relationship][:relationship_type])
        redirect_to admin_user_path(@guardian), notice: t(relationship_create_pass)
      else
        @dependent = dependent_user
        @guardian_relationship = GuardianRelationship.new(
          guardian_user: @guardian,
          dependent_user: @dependent,
          relationship_type: params[:guardian_relationship][:relationship_type]
        )
        log_user_service_error('to create guardian relationship', 'Relationship creation failed')
        flash.now[:alert] = t(relationship_create_fail)
        render :new, status: :unprocessable_content
      end
    end

    def destroy
      guardian = @guardian_relationship.guardian_user
      dependent = @guardian_relationship.dependent_user

      if @guardian_relationship.destroy
        redirect_to admin_user_path(params[:return_to] == 'dependent' ? dependent : guardian),
                    notice: t(relationship_remove_pass)
      else
        redirect_to admin_user_path(params[:return_to] == 'dependent' ? dependent : guardian),
                    alert: t(relationship_remove_fail)
      end
    end

    private

    def set_guardian
      @guardian = User.find(params[:guardian_id])
    end

    def set_relationship
      @guardian_relationship = GuardianRelationship.find(params[:id])
    end

    def guardian_relationship_params
      params.expect(guardian_relationship: %i[dependent_id relationship_type])
    end
  end
end
