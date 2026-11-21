# frozen_string_literal: true

module Applications
  # The admin list reads fulfillment through its existing owner; application status stays approved.
  class ApprovedPipeline
    Definition = Equipment::FulfillmentStage::Definition
    Row = Data.define(:application, :group, :stage, :entered_at, :days, :action_label, :progress, :evaluation, :voucher,
                      :remaining_value, :secondary, :action_context, :icanconnect_work)
    Summary = Data.define(:stage, :label, :count, :oldest, :average_days, :unknown_dates, :remaining_value)

    STAGES = {
      equipment: Equipment::FulfillmentStage::DEFINITIONS,
      voucher: [Definition.new(:voucher_missing, 'Needs voucher', 'Open application'),
                Definition.new(:voucher_issued, 'Voucher issued', 'View voucher'),
                Definition.new(:voucher_expired, 'Expired with unused value', 'Review voucher'),
                Definition.new(:voucher_used, 'Fully used', 'View voucher'),
                Definition.new(:voucher_cancelled, 'Cancelled', 'View voucher')].freeze,
      none: [Definition.new(:no_equipment, 'No equipment needed', 'View application')].freeze
    }.freeze
    STAGE_FILTERS = {
      awaiting_evaluation: { label: 'Awaiting evaluation', stages: %i[needs_evaluator awaiting_report] },
      getting_bids: { label: 'Getting bids', stages: %i[needs_fulfillment awaiting_bid_award] }
    }.freeze
    HISTORY_ACTIONS = %w[expired status_changed_to_redeemed status_changed_to_expired status_changed_to_cancelled].freeze

    def initialize(applications, now: Time.current)
      @applications = applications.select(&:status_approved?)
      @now = now
    end

    def self.terminal_stage?(stage)
      %i[shipment_recorded voucher_used voucher_cancelled].include?(stage)
    end

    def self.stage_filters(group)
      stages = STAGES.fetch(group).to_h { |definition| [definition.key.to_s, [definition.key]] }
      return stages unless group == :equipment

      stages.merge(STAGE_FILTERS.transform_keys(&:to_s).transform_values { |filter| filter.fetch(:stages) })
    end

    def self.sort_rows(rows)
      rows.sort_by do |row|
        terminal = terminal_stage?(row.stage)
        timestamp = row.entered_at ? row.entered_at.to_f : Float::INFINITY
        timestamp = -timestamp if terminal && row.entered_at
        [terminal ? 1 : 0, timestamp, row.application.id]
      end
    end

    def rows
      @rows ||= begin
        load_dependencies
        @applications.map { |application| build_row(application) }
      end
    end

    def groups
      @groups ||= STAGES.to_h { |group, _definitions| [group, rows.select { |row| row.group == group }] }
    end

    def summaries(group)
      STAGES.fetch(group).map do |definition|
        selected = groups.fetch(group).select { |row| row.stage == definition.key }
        dated = selected.select(&:entered_at)
        oldest = self.class.terminal_stage?(definition.key) ? dated.max_by(&:entered_at) : dated.min_by { |row| [row.entered_at, row.application.id] }
        evaluation = oldest&.evaluation
        ActiveRecord::Associations::Preloader.new(records: [evaluation], associations: :evaluator).call if evaluation
        Summary.new(stage: definition.key, label: definition.label, count: selected.length,
                    oldest:,
                    average_days: dated.any? ? (dated.sum(&:days).to_f / dated.length).round : nil,
                    unknown_dates: selected.length - dated.length, remaining_value: selected.sum(&:remaining_value))
      end
    end

    private

    def load_dependencies
      Application.preload_equipment_fulfillment(@applications, include_display_details: false)
      voucher_applications = @applications.select(&:voucher_fulfillment?)
      ActiveRecord::Associations::Preloader.new(records: voucher_applications, associations: :vouchers).call
      ids = @applications.map(&:id)
      @training_application_ids = TrainingSession.where(application_id: ids).distinct.pluck(:application_id)
      load_voucher_history(voucher_applications)
    end

    def load_voucher_history(voucher_applications)
      voucher_ids = voucher_applications.flat_map { |application| application.vouchers.map(&:id) }
      @history = Event.where(auditable_type: 'Voucher', auditable_id: voucher_ids)
                      .where(action: HISTORY_ACTIONS).order(:created_at, :id).group_by(&:auditable_id)
    end

    def build_row(application)
      return voucher_row(application) if application.voucher_fulfillment?

      fulfillment = application.equipment_fulfillment_stage(now: @now)
      stage = fulfillment.stage
      group = stage == :no_equipment ? :none : :equipment
      entered_at = fulfillment.entered_at
      training = stage == :no_equipment && training_on_file?(application)
      Row.new(application:, group:, stage:, entered_at:, days: Equipment::WaitTime.days_since(entered_at, now: @now),
              action_label: training ? 'Open training' : fulfillment.action,
              progress: fulfillment.progress, evaluation: stage == :awaiting_report ? application.open_equipment_evaluations.last : nil, voucher: nil,
              remaining_value: 0.to_d, secondary: fulfillment.secondary, action_context: fulfillment.action_context, icanconnect_work: nil)
    end

    def voucher_row(application)
      stage, selected = voucher_selection(application.vouchers)
      voucher = selected.min_by { |entry| [entry.issued_at || entry.created_at, entry.id] }
      entered_at = voucher_entry(application, stage, voucher)
      remaining_value = selected.sum(&:remaining_value).to_d
      progress = voucher_progress(stage, voucher, remaining_value, entered_at)
      Row.new(application:, group: :voucher, stage:, entered_at:, days: Equipment::WaitTime.days_since(entered_at, now: @now),
              action_label: definition(:voucher, stage).action, progress:, evaluation: nil, voucher:, remaining_value:,
              secondary: [], action_context: {}, icanconnect_work: pending_icanconnect_work(application))
    end

    def pending_icanconnect_work(application)
      return unless application.equipment_needs_initialized_at?

      work = application.equipment_fulfillment_stage(now: @now)
      work if work.stage.in?(%i[needs_fulfillment awaiting_bid_award ready_to_send_po awaiting_shipment awaiting_delivery])
    end

    def voucher_selection(vouchers)
      spendable = vouchers.reject { |voucher| voucher.voucher_cancelled? || voucher.voucher_redeemed? || voucher.remaining_value.zero? }
      choices = {
        voucher_expired: spendable.select(&:expired?),
        voucher_issued: spendable.select(&:voucher_active?).reject(&:expired?),
        voucher_used: vouchers.reject(&:voucher_cancelled?).select { |voucher| voucher.voucher_redeemed? || voucher.remaining_value.zero? },
        voucher_cancelled: vouchers.to_a
      }
      choices.find { |_stage, selected| selected.any? } || [:voucher_missing, []]
    end

    def voucher_progress(stage, voucher, remaining_value, entered_at)
      return 'Voucher cancelled · cannot be used' if stage == :voucher_cancelled
      return 'Voucher fully used · $0.00 remaining' if stage == :voucher_used
      return 'No voucher has been issued' unless voucher

      text = "#{format('$%.2f', remaining_value)} remaining"
      expiration = stage == :voucher_expired ? entered_at : voucher.expiration_date
      return "Voucher expired · #{text}" if stage == :voucher_expired && expiration.nil?

      if expiration
        label = stage == :voucher_expired ? 'expired' : 'expires'
        text += " · #{label} #{expiration.to_date.to_fs(:long)}"
      end
      text
    end

    def voucher_entry(application, stage, voucher)
      return application.current_status_entered_at unless voucher
      return voucher.issued_at if stage == :voucher_issued

      history = @history.fetch(voucher.id, [])
      if stage == :voucher_expired
        return voucher.expiration_date unless voucher.voucher_expired?

        expiration = history.rfind { |event| event.action == 'expired' }
        return Time.iso8601(expiration.metadata.fetch('expiration_date')) if expiration
      end

      action = { voucher_expired: 'status_changed_to_expired', voucher_used: 'status_changed_to_redeemed', voucher_cancelled: 'status_changed_to_cancelled' }[stage]
      history.rfind { |event| event.action == action }&.created_at
    end

    def definition(group, stage)
      STAGES.fetch(group).find { |entry| entry.key == stage }
    end

    def training_on_file?(application)
      application.training_requested_at.present? || @training_application_ids.include?(application.id)
    end
  end
end
