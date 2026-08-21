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
    #
    # The explicit messages are only half of it: the query itself sends these names to the database,
    # and a positional bind is logged without an attribute name for the filter to match. See
    # case_insensitive_match below.
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

        # Counting is a second query, so it stays inside the level check rather than running
        # unconditionally to build a message that is usually discarded.
        Rails.logger.debug { "find_duplicates: #{query.count} match(es)" } if Rails.logger.debug?

        query
      end

      # Built through Arel with a *named* bind rather than `where('LOWER(col) = ?', value)`.
      #
      # A positional bind is anonymous: Active Record logs it as `[nil, "smith"]`, and
      # `config.filter_parameters` matches on the attribute name, so it has nothing to match and the
      # value is written to the query log in the clear. The date of birth beside it was filtered the
      # whole time precisely because a hash condition carries its column name. Naming the bind is
      # what lets the existing filter do its job -- the same query, logged as
      # `["first_name", "[FILTERED]"]`.
      def case_insensitive_match(column, value)
        bind = ActiveRecord::Relation::QueryAttribute.new(
          column.to_s, value.to_s.downcase, ActiveRecord::Type::String.new
        )
        Arel::Nodes::NamedFunction.new('LOWER', [arel_table[column]])
                                  .eq(Arel::Nodes::BindParam.new(bind))
      end
    end

    private

    def must_have_at_least_one_disability
      return if hearing_disability || vision_disability || speech_disability || mobility_disability || cognition_disability

      errors.add(:base, 'At least one disability must be selected.')
    end
  end
end
