# frozen_string_literal: true

module Users
  class Constituent < User
    has_many :applications, foreign_key: :user_id, dependent: :destroy
    has_many :evaluations
    has_many :assigned_evaluators, through: :evaluations, source: :evaluator

    enum :communication_preference, { email: 0, letter: 1 }

    encrypts :date_of_birth, deterministic: true

    scope :needs_evaluation, -> { joins(:applications).where(applications: { status: :approved }) }
    scope :active, -> { where.not(status: %i[withdrawn rejected expired]) }
    scope :ytd, lambda {
      where(created_at: FiscalYear.start_date_for(FiscalYear.current_start_year)..)
    }

    DISABILITY_TYPES = %w[hearing vision speech mobility cognition].freeze

    DISABILITY_TYPES.each do |type|
      attribute :"#{type}_disability", :boolean, default: false

      define_method("#{type}_disability=") do |value|
        super(ActiveModel::Type::Boolean.new.cast(value))
      end
    end

    def active_application?
      active_application.present?
    end

    def active_application
      applications.active.order(application_date: :desc).first
    end

    def disability_selected?
      hearing_disability || vision_disability || speech_disability || mobility_disability || cognition_disability
    end

    # Identity-matching path. Paper intake calls it for each new applicant. Keep log messages PII-free.
    # `config.filter_parameters` does not redact values interpolated into a message, so log only
    # counts and types. To find which records matched, run the query in a console.
    # The SQL log is also a risk. See case_insensitive_match.
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
        query = where(case_insensitive_match(:first_name, first_name))
                .where(case_insensitive_match(:last_name, last_name))
                .where(date_of_birth: formatted_date)

        # The count is a second query, so it runs only at debug level.
        Rails.logger.debug { "find_duplicates: #{query.count} match(es)" } if Rails.logger.debug?

        query
      end

      # Uses a named Arel bind, not `where('LOWER(col) = ?', value)`. Active Record logs a
      # positional bind as `[nil, "smith"]`, and `config.filter_parameters` cannot filter a bind
      # with no name. A named bind logs as `["first_name", "[FILTERED]"]`.
      def case_insensitive_match(column, value)
        bind = ActiveRecord::Relation::QueryAttribute.new(
          column.to_s, value.to_s.downcase, ActiveRecord::Type::String.new
        )
        Arel::Nodes::NamedFunction.new('LOWER', [arel_table[column]])
                                  .eq(Arel::Nodes::BindParam.new(bind))
      end
    end
  end
end
