# frozen_string_literal: true

module Vendors
  class ReviewW9 < BaseService
    def initialize(vendor:, admin:, attributes:)
      super()
      @vendor = vendor
      @admin = admin
      @attributes = attributes.to_h.symbolize_keys
    end

    def call
      review = @vendor.w9_reviews.build(@attributes.except(:status).merge(admin: @admin))
      unless %w[approved rejected].include?(@attributes[:status].to_s)
        review.errors.add(:status, 'must be explicitly approved or rejected')
        return failure('Choose approval or rejection.', { review: review })
      end

      review.status = @attributes[:status]
      result = nil
      @vendor.with_lock do
        blob = @vendor.w9_form.blob
        unless blob && blob.id.to_s == @attributes[:reviewed_blob_id].to_s && @vendor.w9_status_pending_review?
          review.errors.add(:base, 'This document is no longer awaiting review. Reload the vendor before deciding.')
          return failure(review.errors.full_messages.to_sentence, { review: review })
        end
        blob.lock!
        review.reviewed_blob = blob
        review.save!
        W9Document.protect!(blob, vendor: @vendor)
        @vendor.w9_archive.attach(blob) unless @vendor.w9_archive.blobs.exists?(blob.id)
        @vendor.w9_status = review.status
        @vendor.w9_rejections_count += 1 if review.status_rejected?
        @vendor.save!
        AuditEventService.log(action: "w9_#{review.status}", actor: @admin, auditable: @vendor,
                              metadata: review_metadata(review))
        result = success('W9 review completed successfully', { review: review, delivery: 'pending' })
        ActiveRecord.after_all_transactions_commit { deliver_follow_up(review, result) }
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence, { review: review })
    rescue ActiveRecord::RecordNotUnique
      review.errors.add(:base, 'This document has already been reviewed.')
      failure(review.errors.full_messages.to_sentence, { review: review })
    end

    private

    def review_metadata(review)
      { w9_review_id: review.id, reviewed_blob_id: review.reviewed_blob_id,
        rejection_reason_code: review.rejection_reason_code, rejection_reason: review.rejection_reason }
    end

    def deliver_follow_up(review, result)
      notification = NotificationService.create_and_deliver!(
        type: "w9_#{review.status}", recipient: @vendor, actor: @admin, notifiable: @vendor,
        metadata: review_metadata(review), channel: :email, deliver: review.status_approved?
      )
      if review.status_rejected?
        delivery = RequestW9Resubmission.new(vendor: @vendor, actor: @admin, review: review).call
        result.data[:delivery] = delivery.success? ? 'requested' : delivery.message
      else
        result.data[:delivery] = notification&.reload&.delivery_status || 'failed'
      end
      notify_rejection_limit if review.status_rejected? && @vendor.w9_rejections_count >= 8
    rescue StandardError => e
      result.data[:delivery] = 'failed'
      Rails.logger.error("W9 review #{review.id} follow-up failed (#{e.class})")
    end

    def notify_rejection_limit
      recipient = User.admins.first
      return unless recipient

      NotificationService.create_and_deliver!(type: 'vendor_max_w9_rejections_warning', recipient: recipient,
                                              actor: @admin, notifiable: @vendor, channel: :email, audit: true)
    end
  end
end
