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
    # Diagnostics here are deliberately PII-free. This is the identity-matching path -- its
    # arguments are a name and a date of birth, and its results are the people who matched -- and
    # paper intake now calls it on every new-applicant submission. `config.filter_parameters`
    # redacts params, not strings a developer interpolated into a log message, so anything named
    # here would land in the log in the clear. Counts and shapes are what debugging actually needs.
    # Identifying *which* records matched is deliberately not obtainable from the log at all -- run
    # the same query in a console against the request's own parameters instead.
    def self.find_duplicates(first_name, last_name, date_of_birth)
      return none if invalid_duplicate_params?(first_name, last_name, date_of_birth)

      formatted_date = format_date_for_encryption(date_of_birth)
      if formatted_date.nil?
        Rails.logger.debug { "find_duplicates: unusable date_of_birth (#{date_of_birth.class})" }
        return none
      end

      build_duplicate_query(first_name, last_name, formatted_date)
    end

    class << self
      private

      def invalid_duplicate_params?(first_name, last_name, date_of_birth)
        first_name.blank? || last_name.blank? || date_of_birth.blank?
      end

      def format_date_for_encryption(date_of_birth)
        case date_of_birth
        when String then Date.iso8601(date_of_birth)
        when Date then date_of_birth
        end
      rescue ArgumentError
        nil
      end

      def build_duplicate_query(first_name, last_name, formatted_date)
        query = where('LOWER(first_name) = ? AND LOWER(last_name) = ?',
                      first_name.downcase, last_name.downcase)
                .where(date_of_birth: formatted_date)

        # Counting is a second query, so it stays inside the level check rather than running
        # unconditionally to build a message that is usually discarded.
        Rails.logger.debug { "find_duplicates: #{query.count} match(es)" } if Rails.logger.debug?

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
