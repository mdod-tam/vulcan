# frozen_string_literal: true

namespace :data do
  desc 'Update legacy status names to new terminology in ApplicationStatusChange records'
  task update_status_names: :environment do
    puts 'Updating legacy status names in ApplicationStatusChange records...'

    # Update awaiting_documents → awaiting_dcf
    awaiting_docs_from = ApplicationStatusChange.where(from_status: 'awaiting_documents')
                                                .update_all(from_status: 'awaiting_dcf') # rubocop:disable Rails/SkipsModelValidations
    awaiting_docs_to = ApplicationStatusChange.where(to_status: 'awaiting_documents')
                                              .update_all(to_status: 'awaiting_dcf') # rubocop:disable Rails/SkipsModelValidations

    # Update needs_information → awaiting_proof
    needs_info_from = ApplicationStatusChange.where(from_status: 'needs_information')
                                             .update_all(from_status: 'awaiting_proof') # rubocop:disable Rails/SkipsModelValidations
    needs_info_to = ApplicationStatusChange.where(to_status: 'needs_information')
                                           .update_all(to_status: 'awaiting_proof') # rubocop:disable Rails/SkipsModelValidations

    total_count = awaiting_docs_from + awaiting_docs_to + needs_info_from + needs_info_to

    puts "✓ Updated #{total_count} status change records:"
    puts "  - awaiting_documents → awaiting_dcf: #{awaiting_docs_from + awaiting_docs_to}"
    puts "  - needs_information → awaiting_proof: #{needs_info_from + needs_info_to}"
    puts 'All legacy status references have been updated to new terminology'
  end
end
