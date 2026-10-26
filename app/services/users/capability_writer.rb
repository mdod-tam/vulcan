# frozen_string_literal: true

module Users
  # The only writer for staff capability grants and role changes.
  #
  # Lock order, as everywhere users and work interact: the acting administrator and the target in ascending id order
  # (User.lock_for_merge_integrity!), then the affected Applications in id order, then their Evaluations and
  # TrainingSessions in id order. Assignment writers lock the assignee before the Application, so a grant change
  # and an assignment serialize on the target user instead of deadlocking.
  #
  # Removing access from someone with open assigned work needs a confirmation bound to that exact work. A
  # confirmed or harmless change commits with its audit events and one operation receipt in the same transaction.
  # Replaying an operation id returns its first outcome without evaluating current state again.
  class CapabilityWriter
    PURPOSE = 'staff_capability_impact:v1'
    TOKEN_TTL = 15.minutes
    RECEIPT_ACTION = 'staff_capability_operation_applied'

    DISCIPLINES = {
      'can_evaluate' => { model: Evaluation, assignee: :evaluator_id, noun: 'evaluation', removed_action: 'evaluator_access_removed' },
      'can_train' => { model: TrainingSession, assignee: :trainer_id, noun: 'training session', removed_action: 'trainer_access_removed' }
    }.freeze

    Intent = Data.define(:kind, :capability, :role) do
      def self.grant(capability) = new(kind: :grant, capability: capability.to_s, role: nil)
      def self.revoke(capability) = new(kind: :revoke, capability: capability.to_s, role: nil)
      def self.change_role(klass) = new(kind: :role, capability: nil, role: klass)

      def normalized = { 'kind' => kind.to_s, 'capability' => capability.to_s, 'role' => role&.name.to_s }
    end

    # One lost capability's open work: [row id, application id, assignee id, updated_at] per assignment, plus
    # applications whose trainer coverage names the target.
    Impact = Data.define(:capability, :noun, :rows, :coverage_application_ids) do
      def open_count = rows.size
      def application_ids = (rows.map { |row| row[1] } + coverage_application_ids).uniq.sort
    end

    Result = Data.define(:status, :user, :message, :impact, :token) do
      def success? = %i[changed unchanged already_applied].include?(status)
      def changed? = status == :changed
    end

    def self.call(**) = new(**).call

    def initialize(actor:, user:, intent:, operation_id:, confirmation: nil)
      @actor = actor
      @user = user
      @intent = intent
      @operation_id = operation_id.to_s
      @confirmation = confirmation.to_s
      raise ArgumentError, 'operation_id is required' if @operation_id.blank?
    end

    def call
      ApplicationRecord.transaction do
        locked = User.lock_for_merge_integrity!(@actor, @user)
        @actor = locked.fetch(@actor.id)
        @target = locked.fetch(@user.id)
        perform
      end
    end

    private

    def perform
      return refuse('Your admin session is no longer eligible for this action.') unless @actor.admin? && @actor.public_login_active?
      return refuse('This record is no longer an eligible active record.') if @target.merged?

      receipt = receipt_event
      return replay(receipt) if receipt
      return refuse('You cannot change your own role.') if @intent.kind == :role && @actor.id == @target.id

      @before = @target.effective_capabilities
      change = plan
      return change if change.is_a?(Result)

      @after = change.fetch(:after)
      @impacts = lost_access_impacts
      return @impacts if @impacts.is_a?(Result)

      verdict = confirmation_verdict
      return verdict if verdict

      change.fetch(:apply).call
      @target.role_capabilities.reset
      record_audit
      finish(change.fetch(:status), change.fetch(:message))
    end

    # Returns a Result for a refusal or a harmless no-op, or what to write.
    def plan
      case @intent.kind
      when :grant then grant_plan
      when :revoke then revoke_plan
      when :role then role_plan
      end
    end

    def grant_plan
      capability = @intent.capability
      return noop("#{label(capability)} is already granted.") if @target.explicit_grant?(capability)

      grant = @target.role_capabilities.build(capability: capability)
      return refuse(grant.errors.full_messages.to_sentence) unless grant.valid?

      { status: :changed, after: @before | [capability], message: "Added #{label(capability)} capability.",
        apply: -> { grant.save! } }
    end

    def revoke_plan
      capability = @intent.capability
      stored = @target.role_capabilities.where(capability: capability)
      if stored.none?
        return refuse("#{label(capability)} comes with this role and cannot be removed.") if @target.role_provided_capabilities.include?(capability)

        return noop("#{label(capability)} is not granted.")
      end

      { status: :changed, after: (@before - [capability]) | @target.role_provided_capabilities.intersection([capability]),
        message: "Removed #{label(capability)} capability.", apply: -> { stored.destroy_all } }
    end

    def role_plan
      klass = @intent.role
      return noop("#{@target.full_name}'s role is already #{role_name(klass)}.") if @target.type == klass.name
      return refuse('Add a date of birth before making this user a constituent.') if klass <= Users::Constituent && @target.date_of_birth.blank?

      { status: :changed, after: UserRolesAndCapabilities::CAPABILITY_MATRIX.dig(klass.name.demodulize, :provides).to_a,
        message: "#{@target.full_name}'s role updated to #{role_name(klass)}.", apply: -> { convert_role!(klass) } }
    end

    # Explicit grants never survive a role change: effective access comes from the new role alone.
    def convert_role!(klass)
      @from_role = @target.type
      @target.role_capabilities.destroy_all
      converted = @target.becomes(klass)
      converted.type = klass.name
      # Column defaults, not nil: w9_status and w9_rejections_count are NOT NULL.
      if @from_role == 'Users::Vendor' && !converted.is_a?(Users::Vendor)
        Users::Vendor::VENDOR_ONLY_ATTRIBUTES.each { |attribute| converted[attribute] = User.column_defaults[attribute] }
      end
      converted.save!(validate: false)
    end

    # Locks the applications, then the work rows, of every lost capability and reads the open assignments again.
    # The target's user lock already holds back new assignments and new rows that reference the target.
    def lost_access_impacts
      lost = @before - @after
      return [] if lost.empty?

      disciplines = DISCIPLINES.slice(*DISCIPLINES.keys.intersection(lost))
      application_ids = disciplines.flat_map { |capability, config| unlocked_application_ids(capability, config) }.uniq.sort
      locked = Application.where(id: application_ids).order(:id).lock('FOR UPDATE').index_by(&:id)
      @locked_applications = locked
      impacts = disciplines.filter_map { |capability, config| impact_for(capability, config) }
      return stale_result(impacts) unless impacts.flat_map(&:application_ids).all? { |id| locked.key?(id) }

      impacts.reject { |impact| impact.rows.empty? && impact.coverage_application_ids.empty? }
    end

    def unlocked_application_ids(capability, config)
      ids = config[:model].open_assigned.where(config[:assignee] => @target.id).pluck(:application_id)
      ids += Application.where(assigned_trainer_id: @target.id).pluck(:id) if capability == 'can_train'
      ids
    end

    def impact_for(capability, config)
      rows = config[:model].open_assigned.where(config[:assignee] => @target.id).order(:id).lock('FOR UPDATE')
                           .map { |row| [row.id, row.application_id, @target.id, row.updated_at.utc.iso8601(6)] }
      coverage = capability == 'can_train' ? @locked_applications.values.select { |app| app.assigned_trainer_id == @target.id }.map(&:id) : []
      Impact.new(capability: capability, noun: config[:noun], rows: rows, coverage_application_ids: coverage)
    end

    def confirmation_verdict
      return if @impacts.empty?

      digest = impact_digest
      return Result.new(status: :confirmation_required, user: @target, message: nil, impact: @impacts, token: issue_token(digest)) if @confirmation.blank?
      return if confirmed?(digest)

      stale_result(@impacts, digest)
    end

    def stale_result(impacts, digest = nil)
      @impacts = impacts.reject { |impact| impact.rows.empty? && impact.coverage_application_ids.empty? }
      Result.new(status: :stale, user: @target, impact: @impacts, token: issue_token(digest || impact_digest),
                 message: 'This access changed or the confirmation expired. Review the current work and confirm again.')
    end

    # Equal counts do not establish equal impact, so the digest covers each affected row and its version.
    def impact_digest
      state = {
        role: [@target.type, @target.status, @target.merged_into_user_id],
        grants: @target.role_capabilities.reload.map { |grant| [grant.id, grant.capability, grant.updated_at.utc.iso8601(6)] }.sort,
        work: @impacts.map { |impact| [impact.capability, impact.rows.sort, impact.coverage_application_ids.sort] }.sort
      }
      Digest::SHA256.hexdigest(JSON.generate(state))
    end

    def issue_token(digest)
      verifier.generate(token_payload(digest), purpose: PURPOSE, expires_in: TOKEN_TTL)
    end

    def confirmed?(digest)
      payload = verifier.verified(@confirmation, purpose: PURPOSE)
      payload.is_a?(Hash) && ActiveSupport::SecurityUtils.secure_compare(payload.to_json, token_payload(digest).to_json)
    end

    def token_payload(digest)
      { 'actor_id' => @actor.id, 'target_id' => @target.id, 'operation_id' => @operation_id,
        'intent' => @intent.normalized, 'digest' => digest }
    end

    def verifier = Rails.application.message_verifier(PURPOSE)

    def record_audit
      reason = @intent.kind == :role ? 'role_changed' : 'capability_removed'
      (@before - @after).each { |capability| log_capability_event('capability_removed', capability, reason) }
      (@after - @before).each { |capability| log_capability_event('capability_granted', capability, @intent.kind == :role ? 'role_changed' : 'capability_granted') }
      @impacts.each { |impact| log_access_removed(impact, reason) }
    end

    # Write identity includes the capability, so two losses for one target in one operation stay separate events.
    def log_capability_event(action, capability, reason)
      role_provided = (action == 'capability_removed' ? role_before : @target.role_provided_capabilities).include?(capability)
      AuditEventService.log(
        action: action, actor: @actor, auditable: @target,
        metadata: { operation_id: "#{@operation_id}:#{capability}", correlation_id: @operation_id, capability: capability,
                    source: role_provided ? 'role' : 'explicit_grant', reason: reason, acting_admin_id: @actor.id,
                    before_access: @before, after_access: @after, from_role: @from_role || @target.type, to_role: @target.type }
      ) || raise("The #{action} audit was not recorded")
    end

    def log_access_removed(impact, reason)
      config = DISCIPLINES.fetch(impact.capability)
      impact.application_ids.each do |application_id|
        AuditEventService.log(
          action: config[:removed_action], actor: @actor, auditable: @locked_applications.fetch(application_id),
          metadata: { operation_id: @operation_id, correlation_id: @operation_id, application_id: application_id,
                      former_practitioner_id: @target.id, reason: reason,
                      "#{config[:noun].tr(' ', '_')}_ids" => impact.rows.select { |row| row[1] == application_id }.map(&:first) }
        ) || raise("The #{config[:removed_action]} audit was not recorded")
      end
    end

    def role_before
      @role_before ||= @from_role ? UserRolesAndCapabilities::CAPABILITY_MATRIX.dig(@from_role.demodulize, :provides).to_a : @target.role_provided_capabilities
    end

    def finish(status, message)
      AuditEventService.log(
        action: RECEIPT_ACTION, actor: @actor, auditable: @target,
        metadata: { operation_id: @operation_id, actor_id: @actor.id, intent: @intent.normalized,
                    outcome: status.to_s, message: message }
      ) || raise('The operation receipt was not recorded')
      Result.new(status: status, user: @target, message: message, impact: nil, token: nil)
    end

    def receipt_event
      Event.where(action: RECEIPT_ACTION, auditable: @target).with_metadata(:operation_id, @operation_id).order(:id).last
    end

    def replay(receipt)
      metadata = receipt.metadata
      return refuse('This operation id was already used for a different change.') unless metadata['actor_id'] == @actor.id && metadata['intent'] == @intent.normalized

      Result.new(status: :already_applied, user: @target, message: metadata['message'], impact: nil, token: nil)
    end

    # An accepted no-op writes its own receipt so a later retry cannot turn it into a destructive change.
    def noop(message)
      finish(:unchanged, message)
    end

    def refuse(message)
      Result.new(status: :refused, user: @target || @user, message: message, impact: nil, token: nil)
    end

    def label(capability) = capability.to_s.titleize

    def role_name(klass) = klass.name.demodulize.titleize
  end
end
