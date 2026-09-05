# frozen_string_literal: true

require 'csv'

module DuplicateReconciliation
  class Report
    CSV_HEADERS = %w[
      pair_key
      state
      first_user_id
      first_user_name
      first_user_email_present
      first_user_phone_present
      first_user_application_summary
      first_user_needs_duplicate_review
      second_user_id
      second_user_name
      second_user_email_present
      second_user_phone_present
      second_user_application_summary
      second_user_needs_duplicate_review
    ].freeze

    Result = Data.define(:pairs, :csv_path)

    def initialize(population: Population.new)
      @population = population
    end

    def call(output: $stdout, csv_path: nil)
      pairs = @population.pairs(include_historical: true)
      write_text(output, pairs)
      write_csv(csv_path, pairs) if csv_path.present?
      Result.new(pairs: pairs, csv_path: csv_path.presence)
    end

    private

    def write_text(output, pairs)
      output.puts 'Post-import duplicate reconciliation report'
      output.puts "Pairs: #{pairs.size}"
      pairs.each do |pair|
        output.puts "Pair #{pair.ids.join('-')}: #{pair.state.to_s.tr('_', '-')}"
        output.puts "  #{member_text(pair.first)}"
        output.puts "  #{member_text(pair.second)}"
      end
    end

    def member_text(member)
      "##{member.id} #{member.name} | email present: #{yes_no(member.real_email)} | " \
        "phone present: #{yes_no(member.real_phone)} | applications: #{member.application_summary} | " \
        "review flag: #{yes_no(member.needs_duplicate_review)}"
    end

    def write_csv(path, pairs)
      CSV.open(path, 'w', write_headers: true, headers: CSV_HEADERS) do |csv|
        pairs.each { |pair| csv << csv_row(pair) }
      end
    end

    def csv_row(pair)
      [
        pair.ids.join('-'),
        pair.state,
        *member_csv_fields(pair.first),
        *member_csv_fields(pair.second)
      ]
    end

    def member_csv_fields(member)
      [
        member.id,
        member.name,
        member.real_email,
        member.real_phone,
        member.application_summary,
        member.needs_duplicate_review
      ]
    end

    def yes_no(value)
      value ? 'yes' : 'no'
    end
  end
end
