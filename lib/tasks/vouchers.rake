# frozen_string_literal: true

namespace :vouchers do
  def approved_voucher_apps_missing_voucher
    Application
      .where.missing(:vouchers)
      .where(
        fulfillment_type: Application.fulfillment_types.fetch('voucher'),
        status: Application.statuses.fetch('approved'),
        residency_proof_status: Application.residency_proof_statuses.fetch('approved'),
        id_proof_status: Application.id_proof_statuses.fetch('approved'),
        medical_certification_status: Application.medical_certification_statuses.fetch('approved')
      )
      .where(
        'applications.income_proof_required = ? OR applications.income_proof_status = ?',
        false,
        Application.income_proof_statuses.fetch('approved')
      )
  end

  desc 'Report approved voucher-fulfillment apps missing a voucher'
  task report_missing: :environment do
    missing_applications = approved_voucher_apps_missing_voucher

    puts "Found #{missing_applications.count} approved voucher applications missing a voucher."
    missing_applications.find_each do |application|
      puts "Application ID: #{application.id}, User ID: #{application.user_id}, Approved At: #{application.updated_at}"
    end
  end
end
