# frozen_string_literal: true

module Admin
  class MileageRatesController < BaseController
    include PolicyEditor

    def create
      @mileage_rate = MileageRate.new(params.expect(mileage_rate: %i[effective_on dollars_per_mile]))
      save_rate
    end

    def update
      @mileage_rate = MileageRate.find(params.expect(:id))
      attributes = params.expect(mileage_rate: %i[effective_on dollars_per_mile lock_version])
      raise ActiveRecord::StaleObjectError.new(@mileage_rate, 'update') unless attributes[:lock_version].to_s == @mileage_rate.lock_version.to_s

      @mileage_rate.assign_attributes(attributes.except(:lock_version))
      save_rate
    rescue ActiveRecord::StaleObjectError
      @mileage_rate.reload
      render_policy_error('This rate changed while you were editing. The saved value is shown. Review it before entering your change again.')
    end

    private

    def save_rate
      persist_rate!
      redirect_to admin_policies_path(anchor: 'mileage-rates'), notice: 'Mileage rate saved.', status: :see_other
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.equal?(@mileage_rate)

      render_policy_error(@mileage_rate.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      @mileage_rate.errors.add(:effective_on, 'already has a rate. Edit that rate below.')
      render_policy_error(@mileage_rate.errors.full_messages.to_sentence)
    end

    def persist_rate!
      MileageRate.transaction do
        @mileage_rate.save!
        changes = @mileage_rate.saved_changes.slice('effective_on', 'dollars_per_mile')
        if changes.any?
          AuditEventService.log(action: @mileage_rate.previously_new_record? ? 'mileage_rate_created' : 'mileage_rate_updated',
                                actor: current_user, auditable: @mileage_rate,
                                metadata: { operation_id: SecureRandom.uuid, effective_on: @mileage_rate.effective_on.iso8601,
                                            dollars_per_mile: @mileage_rate.dollars_per_mile.to_s('F'), changes: changes })
        end
      end
    end

    def render_policy_error(message)
      load_policies
      @mileage_rate_error = message
      if @mileage_rate.persisted?
        @mileage_rates.map! { |rate| rate.id == @mileage_rate.id ? @mileage_rate : rate }
      else
        @new_mileage_rate = @mileage_rate
      end
      render 'admin/policies/index', formats: [:html], status: :unprocessable_content
    end
  end
end
