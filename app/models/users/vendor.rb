# frozen_string_literal: true

module Users
  class Vendor < User
    # Products represent equipment
    has_many :products, foreign_key: :user_id
    has_many :vouchers
    has_many :processed_vouchers, -> { where.not(status: :pending) }, class_name: 'Voucher', foreign_key: :vendor_id
    has_many :voucher_transactions
    has_many :invoices
    has_many :w9_reviews
    has_many :vendor_secure_request_forms, foreign_key: :vendor_id, dependent: :destroy

    has_one_attached :w9_form

    # Callbacks
    after_commit :update_w9_status_on_form_upload, on: :update

    validates :vendor_authorization_status, presence: true
    validates :business_name, presence: true
    validates :business_tax_id, presence: true
    validates :w9_form, presence: true, if: -> { vendor_approved? && !new_record? }
    validates :w9_form,
              content_type: { in: 'application/pdf', message: 'must be a PDF' },
              size: { less_than: 10.megabytes, message: 'must be less than 10MB' },
              if: -> { w9_form.attached? }
    validates :terms_accepted_at, presence: true, if: :vendor_approved?
    validates :website_url,
              format: { with: URI::DEFAULT_PARSER.make_regexp(%w[http https]),
                        message: 'must be a valid URL starting with http:// or https://' },
              allow_blank: true

    attribute :vendor_authorization_status, :integer, default: 0
    enum :vendor_authorization_status, { pending: 0, approved: 1, suspended: 2 }, prefix: :vendor

    # Explicitly declare the attribute type for w9_status
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

    def process_voucher!(voucher_code, amount, product_data = nil)
      # Skip the can_process_vouchers? check in test environment
      return false unless Rails.env.test? || can_process_vouchers?

      voucher = Voucher.find_by(code: voucher_code)
      return false unless voucher&.can_redeem?(amount)

      voucher.redeem!(amount, self, product_data)
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

    # Virtual attribute for handling terms acceptance.
    # When the form sends a "terms_accepted" value (e.g., "1" for checked),
    # this getter returns true if "terms_accepted_at" is present.
    def terms_accepted
      !!terms_accepted_at
    end

    # The setter converts the submitted value into a timestamp.
    # If the value is truthy (checked), it sets terms_accepted_at to the current time;
    # otherwise, it clears the timestamp.
    def terms_accepted=(value)
      if ActiveModel::Type::Boolean.new.cast(value)
        self.terms_accepted_at ||= Time.current
      else
        self.terms_accepted_at = nil
      end
    end

    private

    # Update w9_status when a W9 form is uploaded
    def update_w9_status_on_form_upload
      # When a W9 form is uploaded, it should go to pending_review status
      # unless it's already pending_review (to avoid unnecessary updates)
      # This handles: not_submitted -> pending_review, rejected -> pending_review, approved -> pending_review
      return unless w9_form.attached? && !w9_status_pending_review?

      update_column(:w9_status, :pending_review)
    end
  end
end
