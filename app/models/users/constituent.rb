# frozen_string_literal: true

module Users
  class Constituent < User
    has_many :applications, foreign_key: :user_id, dependent: :destroy
    has_many :evaluations
    has_many :assigned_evaluators, through: :evaluations, source: :evaluator

    enum :communication_preference, { email: 0, letter: 1 }

    # Voucher identity checks and name-and-birthdate duplicate detection both need it. Required when
    # the record is created or the date is changed, so an older record without one still saves
    # unrelated edits. Unreadable input already has its own error.
    validates :date_of_birth, presence: true,
                              if: -> { new_record? || will_save_change_to_date_of_birth? },
                              unless: :rejected_date_of_birth_input

    # Set by paper and guardian intake, which must collect at least one disability before the record exists.
    attr_accessor :require_disability_selection

    validate :must_have_disability, if: :validate_disability?
    validate :admin_contact_update_must_remain_reachable, on: :update, if: :validate_admin_contact_update?
    validate :self_service_profile_requires_email_backing, on: :update, if: :self_service_profile_update?

    scope :needs_evaluation, -> { joins(:applications).where(applications: { status: :approved }) }
    scope :active, -> { where.not(status: %i[withdrawn rejected expired]) }
    scope :ytd, lambda {
      where(created_at: FiscalYear.start_date_for(FiscalYear.current_start_year)..)
    }

    DISABILITY_TYPES = %w[hearing vision speech mobility cognition].freeze
    # The attribute names of the disability flags, for permitting and copying them as a group.
    DISABILITY_FLAGS = DISABILITY_TYPES.map { |type| :"#{type}_disability" }.freeze

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

    private

    # A constituent's disabilities are checked once they have an application, or when intake asks for the check.
    def must_have_disability
      errors.add(:base, 'At least one disability must be selected.') unless disability_selected?
    end

    def validate_disability?
      return false if new_record? && !require_disability_selection

      applications.exists? || require_disability_selection
    end

    # Contact details cannot be cleared outside paper intake unless another route still reaches the constituent.
    def admin_contact_update_must_remain_reachable
      return if real_email? || real_phone?
      return if dependent_with_deliverable_contact_email?
      return if PhoneNumber.real?(dependent_phone)

      unless deliver_via_letter?
        errors.add(:communication_preference, 'must be letter when no email or phone is on file')
        return
      end

      return if was_address_only_contact?

      errors.add(:base, 'Cannot clear all contact information outside paper intake.')
    end

    def self_service_profile_requires_email_backing
      errors.add(:email, :blank) unless real_email?
    end

    def validate_admin_contact_update?
      !Current.paper_context && !merge_in_progress
    end

    def self_service_profile_update?
      !Current.paper_context && Current.user == self
    end

    def was_address_only_contact?
      return true if new_record?

      !User.real_email_address?(attribute_in_database(:email)) && !PhoneNumber.real?(attribute_in_database(:phone))
    end

    # A persisted phone-only or address-only constituent can stay editable without an email.
    def email_optional?
      super || (persisted? && (portal_phone_only_without_email? || address_only_contact?))
    end

    class << self
      private

      def invalid_duplicate_params?(first_name, last_name, date_of_birth)
        first_name.blank? || last_name.blank? || date_of_birth.blank?
      end

      def format_date_for_encryption(date_of_birth)
        DateInputNormalizer.normalize(date_of_birth) if date_of_birth.is_a?(String) || date_of_birth.is_a?(Date)
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
