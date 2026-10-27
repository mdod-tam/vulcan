# frozen_string_literal: true

module Admin
  class ConstituentsController < Admin::BaseController
    def type_check
      email = params[:email]
      constituent = Users::Constituent.find_by(email: email)

      if constituent
        render json: {
          id: constituent.id,
          type: constituent.type,
          class: constituent.class.name
        }
      else
        render json: { error: 'Constituent not found' }, status: :not_found
      end
    end
  end
end
