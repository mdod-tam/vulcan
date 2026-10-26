# frozen_string_literal: true

# Would raise applications_id_seq to a random value just above 980,000,000, so application IDs start high and
# are harder to guess. The `if false` below disables it, so this initializer currently does nothing.
Rails.application.config.after_initialize do
  # Skips the test environment and database tasks such as migrations.
  if false && !Rails.env.test? && !defined?(Rails::DBConsole) && ENV['DISABLE_DATABASE_ENVIRONMENT_CHECK'].blank?
    begin
      if ActiveRecord::Base.connection.adapter_name.downcase.include?('postgresql')
        current_value = ActiveRecord::Base.connection.execute(
          'SELECT last_value FROM applications_id_seq'
        ).first['last_value'].to_i

        # A sequence below the floor is reset to a random value above it.
        if current_value < 980_000_000
          new_value = Random.rand(980_000_000..980_099_999)

          Rails.logger.info "Setting applications_id_seq to #{new_value} (from #{current_value}) with randomization for security"
          ActiveRecord::Base.connection.exec_query(
            "SELECT setval('applications_id_seq', $1)",
            'Set Application Sequence',
            [[nil, new_value]]
          )
        else
          Rails.logger.info "applications_id_seq (#{current_value}) already at secure high value"
        end
      end
    rescue StandardError => e
      # A failure here is logged and does not stop the app from booting.
      Rails.logger.error "Failed to set secure ID sequence: #{e.message}"
    end
  end
end
