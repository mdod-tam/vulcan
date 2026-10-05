# frozen_string_literal: true

module Users
  class Vendor < User
    has_many :products, foreign_key: :user_id
    has_many :vouchers
    has_many :processed_vouchers, -> { where.not(status: :pending) }, class_name: 'Voucher', foreign_key: :vendor_id
    has_many :voucher_transactions
    has_many :invoices
    has_many :w9_reviews
    has_many :vendor_secure_request_forms, foreign_key: :vendor_id, dependent: :destroy

    has_one_attached :w9_form

    # A change to these certified fields leaves the W9 on file with old details.
    W9_CERTIFIED_FIELDS = %w[business_name business_tax_id physical_address_1 physical_address_2 city state zip_code].freeze

    after_update :log_w9_details_changed, if: :w9_details_changed_on_file?
    after_save :note_w9_form_attached
    after_commit :update_w9_status_on_form_upload, on: :update

    validates :vendor_authorization_status, presence: true
    validates :business_name, presence: true
    validates :business_tax_id, presence: true
    validates :w9_form, presence: true, if: -> { vendor_approved? && !new_record? }
    validates :w9_form, document: { purpose: :w9 }
    validates :terms_accepted_at, presence: true, if: :vendor_approved?
    validates :website_url,
              format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]),
                        message: 'must be a valid URL starting with http:// or https://' },
              allow_blank: true

    attribute :vendor_authorization_status, :integer, default: 0
    enum :vendor_authorization_status, { pending: 0, approved: 1, suspended: 2 }, prefix: :vendor

    attribute :w9_status, :integer, default: 0
    enum :w9_status, { not_submitted: 0, pending_review: 1, approved: 2, rejected: 3 }, prefix: :w9_status

    scope :active, -> { where(vendor_authorization_status: :approved) }
    scope :with_pending_invoices, lambda {
      joins(:voucher_transactions)
        .where(voucher_transactions: { invoice_id: nil, status: :completed })
        .distinct
    }
    scope :with_pending_w9_reviews, -> { where(w9_status: :pending_review) }

    def pending_transaction_total
      voucher_transactions
        .completed
        .where(invoice_id: nil)
        .sum(:amount)
    end

    def total_transactions_by_period(start_date, end_date)
      voucher_transactions
        .completed
        .where('processed_at BETWEEN ? AND ?', start_date, end_date)
        .group("DATE_TRUNC('month', processed_at)")
        .sum(:amount)
    end

    def can_process_vouchers?
      vendor_approved? && w9_form.attached? && w9_status_approved?
    end

    def can_be_approved?
      business_name.present? &&
        business_tax_id.present? &&
        w9_form.attached? &&
        terms_accepted_at.present?
    end

    def latest_transactions(limit = 10)
      voucher_transactions
        .includes(:voucher)
        .order(processed_at: :desc)
        .limit(limit)
    end

    def uninvoiced_transactions
      voucher_transactions
        .includes(:voucher)
        .completed
        .where(invoice_id: nil)
        .order(processed_at: :desc)
    end

    # W9 link issuance and the admin send button use this rule.
    def w9_requestable_via_secure_form?
      w9_status_not_submitted? || w9_status_rejected?
    end

    def terms_accepted
      !!terms_accepted_at
    end

    # Repeated acceptance preserves the first timestamp. Withdrawal clears it.
    def terms_accepted=(value)
      if ActiveModel::Type::Boolean.new.cast(value)
        self.terms_accepted_at ||= Time.current
      else
        self.terms_accepted_at = nil
      end
    end

    private

    # This callback marks new W9 attachments for review.
    # Profile edits and account lockouts preserve the current W9 status.
    def note_w9_form_attached
      @w9_form_attached_in_save = attachment_changes.key?('w9_form')
    end

    def update_w9_status_on_form_upload
      return unless @w9_form_attached_in_save

      @w9_form_attached_in_save = false
      return if !w9_form.attached? || w9_status_pending_review?

      update_column(:w9_status, :pending_review) # rubocop:disable Rails/SkipsModelValidations
    end

    # A changed name, tax ID, or address does not block vouchers. Staff see it in
    # the W9 history and decide whether to request a new W9.
    def w9_details_changed_on_file?
      w9_form.attached? && (w9_status_approved? || w9_status_pending_review?) &&
        W9_CERTIFIED_FIELDS.any? { |field| saved_change_to_attribute?(field) }
    end

    def log_w9_details_changed
      AuditEventService.log(
        action: 'w9_details_changed',
        actor: Current.user || self,
        auditable: self,
        metadata: {
          changed_fields: W9_CERTIFIED_FIELDS.select { |field| saved_change_to_attribute?(field) },
          w9_status: w9_status
        }
      )
    end
  end
end
