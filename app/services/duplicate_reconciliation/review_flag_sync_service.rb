# frozen_string_literal: true

module DuplicateReconciliation
  class ReviewFlagSyncService < BaseService
    def initialize(user_ids: nil)
      super()
      @user_ids = Array(user_ids).filter_map { |id| Integer(id, exception: false) }.uniq.presence
    end

    def call
      before_count = flag_scope.count
      set_count = 0
      cleared_count = 0

      sync_scope.find_each do |user|
        result = sync_user(user)
        set_count += 1 if result == :set
        cleared_count += 1 if result == :cleared
      end

      success(
        'Duplicate review flags synchronized.',
        {
          before_count: before_count,
          after_count: flag_scope.count,
          set_count: set_count,
          cleared_count: cleared_count
        }
      )
    end

    private

    def sync_scope
      scope = Users::Constituent.where(merged_into_user_id: nil).order(:id)
      @user_ids ? scope.where(id: @user_ids) : scope
    end

    def flag_scope
      Users::Constituent.where(merged_into_user_id: nil, needs_duplicate_review: true)
    end

    def sync_user(user)
      outcome = :unchanged
      ActiveRecord::Base.transaction do
        locked_user = User.lock_for_merge_integrity!(user.id).fetch(user.id)
        unless locked_user.merged?
          # Build the projection only after this participant is locked. Reusing one Population
          # across the whole run would cache pair cases and could overwrite a resolution that
          # committed while synchronization was moving between users.
          required = ReviewFlagProjection.new.required_for?(locked_user)
          if locked_user.needs_duplicate_review? != required
            locked_user.update!(needs_duplicate_review: required)
            outcome = required ? :set : :cleared
          end
        end
      end
      outcome
    end
  end
end
