# frozen_string_literal: true

module Admin
  module VoucherPanelHelper
    VoucherPanelState = Struct.new(:label, :message, :container_class, :label_class)

    def voucher_panel_state(application)
      return disabled_state(existing_voucher: voucher_present?(application)) unless FeatureFlag.enabled?(:vouchers_enabled)
      return issued_state if active_or_redeemed_voucher?(application)

      return ready_state(application) if application.can_create_voucher?

      if application.voucher_successfully_issued?
        return VoucherPanelState.new(
          'Voucher previously issued',
          "This application's voucher entitlement has been fulfilled and cannot be re-issued.",
          'border-blue-300 bg-blue-50 text-blue-900',
          'text-blue-900'
        )
      end

      blocked_state(application)
    end

    def recent_voucher_transactions(voucher, limit: 5)
      voucher
        .transactions
        .sort_by { |transaction| transaction.processed_at || Time.zone.at(0) }
        .reverse
        .first(limit)
    end

    private

    def disabled_state(existing_voucher:)
      message = if existing_voucher
                  'Existing vouchers are shown below, but new voucher issuance is currently disabled.'
                else
                  'Voucher cannot be issued while voucher issuance is disabled.'
                end

      VoucherPanelState.new(
        'Voucher issuance disabled',
        message,
        'border-gray-300 bg-gray-50 text-gray-900',
        'text-gray-900'
      )
    end

    def active_or_redeemed_voucher?(application)
      if application.vouchers.loaded?
        application.vouchers.any? { |voucher| voucher.voucher_active? || voucher.voucher_redeemed? }
      else
        application.vouchers.exists?(status: %i[active redeemed])
      end
    end

    def voucher_present?(application)
      application.vouchers.loaded? ? application.vouchers.any? : application.vouchers.exists?
    end

    def ready_state(application)
      VoucherPanelState.new(
        'Voucher ready',
        ready_for_voucher_message(application),
        'border-amber-300 bg-amber-50 text-amber-900',
        'text-amber-900'
      )
    end

    def issued_state
      VoucherPanelState.new(
        'Voucher issued',
        'A voucher has been issued for this application.',
        'border-green-300 bg-green-50 text-green-900',
        'text-green-900'
      )
    end

    def blocked_state(application)
      VoucherPanelState.new(
        'Voucher blocked',
        voucher_blocking_message(application),
        'border-gray-300 bg-gray-50 text-gray-900',
        'text-gray-900'
      )
    end

    def ready_for_voucher_message(application)
      return 'A previous voucher is cancelled or expired. This application is eligible for a new voucher.' if cancelled_or_expired_voucher?(application)

      'This application is eligible for voucher issuance. Use Assign Voucher only if manual issuance is needed.'
    end

    def voucher_blocking_message(application)
      reasons = []
      reasons << 'the application is not approved' unless application.status_approved?
      reasons << 'required proofs are not all approved' unless application.required_proofs_approved?
      reasons << 'disability certification is not approved' unless application.medical_certification_status_approved?

      if reasons.any?
        "Voucher cannot be issued because #{reasons.to_sentence}."
      else
        'Voucher cannot be issued from the current application state.'
      end
    end

    def cancelled_or_expired_voucher?(application)
      if application.vouchers.loaded?
        application.vouchers.any? { |voucher| voucher.voucher_cancelled? || voucher.voucher_expired? }
      else
        application.vouchers.exists?(status: %i[cancelled expired])
      end
    end
  end
end
