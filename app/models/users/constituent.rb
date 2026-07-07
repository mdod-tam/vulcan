# frozen_string_literal: true

module Users
  class Constituent < User
    # Associations
    has_many :applications, foreign_key: :user_id, dependent: :destroy
    has_many :evaluations
    has_many :assigned_evaluators, through: :evaluations, source: :evaluator
    # Removed unconditional validation: validate :must_have_at_least_one_disability

    # Enums
    enum :communication_preference, { email: 0, letter: 1 }

    # Encryption
    encrypts :date_of_birth, deterministic: true

    # Scopes
    scope :needs_evaluation, -> { joins(:applications).where(applications: { status: :approved }) }
    scope :active, -> { where.not(status: %i[withdrawn rejected expired]) }
    scope :ytd, lambda {
      where(created_at: FiscalYear.start_date_for(FiscalYear.current_start_year)..)
    }

    DISABILITY_TYPES = %w[hearing vision speech mobility cognition].freeze

    # Define disability attributes with defaults
    DISABILITY_TYPES.each do |type|
      attribute :"#{type}_disability", :boolean, default: false

      define_method("#{type}_disability=") do |value|
        super(ActiveModel::Type::Boolean.new.cast(value))
      end
    end

    # Optional: Method to check inherited columns
    def self.inherited_columns
      column_names
    end

    def active_application?
      active_application.present?
    end

    def active_application
      applications.active.order(application_date: :desc).first
    end

    # Public method to check if any disability is selected
    def disability_selected?
      hearing_disability || vision_disability || speech_disability || mobility_disability || cognition_disability
    end

    # Class methods for encrypted lookups
    def self.find_duplicates(first_name, last_name, date_of_birth)
      log_duplicate_search_params(first_name, last_name, date_of_birth)
      return none if invalid_duplicate_params?(first_name, last_name, date_of_birth)

      formatted_date = format_date_for_encryption(date_of_birth)
      return none if formatted_date.nil?

      log_debug_matches(first_name, last_name) if Rails.logger.debug?
      build_duplicate_query(first_name, last_name, formatted_date)
    end

    class << self
      private

      def log_duplicate_search_params(first_name, last_name, date_of_birth)
        Rails.logger.debug do
          "*** find_duplicates called with: first_name=#{first_name}, last_name=#{last_name}, date_of_birth=#{date_of_birth} (#{date_of_birth.class})"
        end
      end

      def invalid_duplicate_params?(first_name, last_name, date_of_birth)
        first_name.blank? || last_name.blank? || date_of_birth.blank?
      end

      def format_date_for_encryption(date_of_birth)
        formatted_date = case date_of_birth
                         when String
                           Date.iso8601(date_of_birth)
                         when Date
                           date_of_birth
                         end

        Rails.logger.debug { "*** Using formatted_date: #{formatted_date} (#{formatted_date.class})" } if formatted_date
        formatted_date
      rescue ArgumentError
        nil
      end

      def log_debug_matches(first_name, last_name)
        all_matching_name = where('LOWER(first_name) = ? AND LOWER(last_name) = ?',
                                  first_name.downcase, last_name.downcase)

        return unless all_matching_name.exists?

        Rails.logger.debug { "*** Found #{all_matching_name.count} name matches" }
        all_matching_name.each do |user|
          user_dob_formatted = user.date_of_birth.is_a?(Date) ? user.date_of_birth.strftime('%Y-%m-%d') : user.date_of_birth
          Rails.logger.debug { "*** User #{user.id}: DOB=#{user.date_of_birth} (#{user.date_of_birth.class}), formatted=#{user_dob_formatted}" }
        end
      end

      def build_duplicate_query(first_name, last_name, formatted_date)
        query = where('LOWER(first_name) = ? AND LOWER(last_name) = ?',
                      first_name.downcase, last_name.downcase)
                .where(date_of_birth: formatted_date)

        if Rails.logger.debug?
          Rails.logger.debug { "*** Duplicate query SQL: #{query.to_sql}" }
          results = query.pluck(:id, :first_name, :last_name)
          Rails.logger.debug { "*** Duplicate query results: #{results.inspect}, count: #{results.count}" }
        end

        query
      end
    end

    private

    def must_have_at_least_one_disability
      return if hearing_disability || vision_disability || speech_disability || mobility_disability || cognition_disability

      errors.add(:base, 'At least one disability must be selected.')
    end
  end
end
