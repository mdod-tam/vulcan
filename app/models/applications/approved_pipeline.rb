# frozen_string_literal: true

module Applications
  # The admin list reads fulfillment through its existing owner; application status stays approved.
  class ApprovedPipeline
    Definition = Data.define(:key, :label, :action)
    Row = Data.define(:application, :group, :stage, :entered_at, :days, :action_label, :progress, :evaluation, :voucher, :remaining_value)
    Summary = Data.define(:stage, :label, :count, :oldest, :average_days, :unknown_dates, :remaining_value)

    STAGES = {
      equipment: [Definition.new(:evaluator, 'Needs evaluator', 'Assign evaluator'),
                  Definition.new(:report, 'Awaiting evaluation report', 'Open evaluation'),
                  Definition.new(:po, 'Awaiting PO', 'Order equipment'),
                  Definition.new(:tracking, 'Awaiting shipment', 'Record shipment'),
                  Definition.new(:recorded, 'Shipment recorded', 'View shipment')].freeze,
      voucher: [Definition.new(:voucher_missing, 'Needs voucher', 'Open application'),
                Definition.new(:voucher_issued, 'Voucher issued', 'View voucher'),
                Definition.new(:voucher_expired, 'Expired with unused value', 'Review voucher'),
                Definition.new(:voucher_used, 'Fully used', 'View voucher'),
                Definition.new(:voucher_cancelled, 'Cancelled', 'View voucher')].freeze,
      none: [Definition.new(:none, 'No equipment needed', 'View application')].freeze
    }.freeze
    EQUIPMENT_STAGES = { needs_action: :po, needs_catalog_product: :po, po_sent: :tracking, shipped: :recorded, no_equipment: :none }.freeze
    HISTORY_ACTIONS = %w[evaluator_assigned evaluation_cancelled equipment_needs_initialized equipment_needs_updated
                         equipment_order_recorded equipment_item_corrected expired status_changed_to_redeemed status_changed_to_expired
                         status_changed_to_cancelled].freeze

    def initialize(applications, now: Time.current)
      @applications = applications.select(&:status_approved?)
      @now = now
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
        Summary.new(stage: definition.key, label: definition.label, count: selected.length,
                    oldest: dated.min_by { |row| [row.entered_at, row.application.id] },
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
      @open_evaluations = Evaluation.open_assigned.where(application_id: ids).order(:id).group_by(&:application_id).transform_values(&:last)
      items = @applications.select(&:equipment_fulfillment?).flat_map(&:equipment_items)
      load_history(ids, items, voucher_applications)
    end

    def load_history(ids, items, voucher_applications)
      voucher_ids = voucher_applications.flat_map { |application| application.vouchers.map(&:id) }
      history = Event.where(auditable_type: 'Application', auditable_id: ids)
                     .or(Event.where(auditable_type: 'Evaluation', auditable_id: Evaluation.where(application_id: ids).select(:id)))
                     .or(Event.where(auditable_type: 'EquipmentItem', auditable_id: items.map(&:id)))
                     .or(Event.where(auditable_type: 'PurchaseOrder', auditable_id: items.filter_map(&:purchase_order_id)))
                     .or(Event.where(auditable_type: 'Voucher', auditable_id: voucher_ids))
                     .where(action: HISTORY_ACTIONS).order(:created_at, :id)
      voucher_owners = voucher_applications.flat_map { |application| application.vouchers.map { |voucher| [voucher.id, application.id] } }.to_h
      @history = Hash.new { |hash, key| hash[key] = [] }
      history.each do |event|
        history_owners(event, voucher_owners).compact.map(&:to_i).uniq.each { |id| @history[id] << event }
      end
    end

    def history_owners(event, voucher_owners)
      case event.auditable_type
      when 'Application' then [event.auditable_id]
      when 'Voucher' then [voucher_owners[event.auditable_id]]
      else Array(event.metadata['application_ids'].presence || event.metadata['application_id'])
      end
    end

    def build_row(application)
      return voucher_row(application) if application.voucher_fulfillment?

      responsibility = application.admin_fulfillment_responsibility_state
      evaluation = @open_evaluations[application.id]
      stage = EQUIPMENT_STAGES.fetch(responsibility) { evaluation ? :report : :evaluator }
      group = stage == :none ? :none : :equipment
      action = if responsibility == :needs_catalog_product
                 'Review equipment'
               elsif stage == :none && training_on_file?(application)
                 'Open training'
               else
                 definition(group, stage).action
               end
      entered_at = equipment_entry(application, stage)
      Row.new(application:, group:, stage:, entered_at:, days: elapsed_days(entered_at), action_label: action,
              progress: equipment_progress(application, stage, responsibility),
              evaluation:, voucher: nil, remaining_value: 0.to_d)
    end

    def voucher_row(application)
      stage, selected = voucher_selection(application.vouchers)
      voucher = selected.min_by { |entry| [entry.issued_at || entry.created_at, entry.id] }
      entered_at = voucher_entry(application, stage, voucher)
      remaining_value = selected.sum(&:remaining_value).to_d
      progress = voucher_progress(stage, voucher, remaining_value, entered_at)
      Row.new(application:, group: :voucher, stage:, entered_at:, days: elapsed_days(entered_at),
              action_label: definition(:voucher, stage).action, progress:, evaluation: @open_evaluations[application.id], voucher:, remaining_value:)
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

    def equipment_progress(application, stage, responsibility)
      if stage == :none
        return 'No equipment needed · training requested' if application.training_requested_at.present?

        return training_on_file?(application) ? 'No equipment needed · training on file' : 'No equipment needed'
      end
      return 'Choose equipment to order' if responsibility == :needs_catalog_product
      return 'Ready for evaluator assignment' if stage == :evaluator
      return 'Evaluator assigned · report not submitted' if stage == :report

      items = application.equipment_items.reject { |item| item.queue_status == 'withdrawn' }
      shipped = items.count { |item| item.queue_status == 'shipped' }
      ordered = items.count { |item| %w[ordered shipped].include?(item.queue_status) }
      total = items.length + application.equipment_needs.sum(&:remaining_quantity)
      "#{ordered} of #{total} #{'item'.pluralize(total)} ordered · #{shipped} shipped"
    end

    def equipment_entry(application, stage)
      history = @history[application.id]
      approval = application.current_status_entered_at
      return evaluation_entry(history, approval, stage) if %i[evaluator report].include?(stage)

      candidate = case stage
                  when :po, :none
                    history.find { |event| %w[equipment_needs_initialized equipment_needs_updated].include?(event.action) }&.created_at
                  when :tracking
                    history.rfind { |event| event.action == 'equipment_order_recorded' }&.created_at
                  when :recorded
                    history.rfind { |event| shipment_recording?(event) }&.created_at
                  end
      return unless candidate
      return if history.any? { |event| event.created_at > candidate && ambiguous_equipment_change?(event) }

      [candidate, approval].compact.max
    end

    def evaluation_entry(history, approval, stage)
      cancellation = history.rfind { |event| event.action == 'evaluation_cancelled' }&.created_at
      baseline = [approval, cancellation].compact.max
      return baseline if stage == :evaluator

      assignment = history.find { |event| event.action == 'evaluator_assigned' && (baseline.nil? || event.created_at >= baseline) }
      assignment&.created_at
    end

    def shipment_recording?(event)
      return false unless event.action == 'equipment_item_corrected'

      before, after = event.field_change_pairs['shipped_at']
      before.blank? && after.present?
    end

    # Ordinary device edits and partial shipments do not restart an application's stage clock.
    # Reopened/corrected work needs a proven boundary; an unknown date is preferable to a guessed one.
    def ambiguous_equipment_change?(event)
      return true if event.action == 'equipment_needs_updated'
      return false unless event.action == 'equipment_item_corrected'

      changes = event.field_change_pairs
      return true if changes.keys.intersect?(%w[purchase_order_id withdrawn_at])

      changes['shipped_at']&.last.blank? && changes.key?('shipped_at')
    end

    def voucher_entry(application, stage, voucher)
      return application.current_status_entered_at unless voucher
      return voucher.issued_at if stage == :voucher_issued

      history = @history[application.id].select { |event| event.auditable_id == voucher.id && event.auditable_type == 'Voucher' }
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

    def elapsed_days(entered_at)
      [((@now - entered_at) / 1.day).floor, 0].max if entered_at
    end
  end
end
