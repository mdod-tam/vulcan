# frozen_string_literal: true

require 'aws-partitions'

# Match storage.yml precedence: a selected blank direct value is invalid, not a fallback.
bucket_setting = ENV.key?('S3_BUCKET') ? 'S3_BUCKET' : 'BUCKETEER_BUCKET_NAME'
region_setting = ENV.key?('S3_REGION') ? 'S3_REGION' : 'BUCKETEER_AWS_REGION'
bucket = ENV.fetch(bucket_setting, nil)
region = ENV[region_setting] || 'us-east-1'
partition = Aws::Partitions.partitions.find { |candidate| candidate.region?(region) }
invalid_settings = []
valid_bucket = bucket.nil? || (bucket.match?(/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/) &&
                              bucket.exclude?('..') && !bucket.match?(/\A\d{1,3}(?:\.\d{1,3}){3}\z/) &&
                              !bucket.start_with?('xn--', 'sthree-', 'amzn-s3-demo-') &&
                              !bucket.end_with?('-s3alias', '--ol-s3', '.mrap', '--x-s3', '--table-s3'))
invalid_settings << bucket_setting unless valid_bucket
invalid_settings << region_setting unless region.match?(/\A[a-z]{2}(?:-gov)?-[a-z]+-\d\z/) && %w[aws aws-us-gov].include?(partition&.name)
if invalid_settings.any?
  raise ArgumentError, "Invalid S3 storage configuration: #{invalid_settings.join(', ')}. " \
                       'Use a lowercase S3 bucket name and a supported commercial or GovCloud region; unset unused variables.'
end

# Proof/document previews in admin (inline disposition). Matches ProofUploadFormats; does not control upload validation.
Rails.application.config.after_initialize do
  Rails.application.config.active_storage.content_types_allowed_inline = ProofUploadFormats::ALLOWED_CONTENT_TYPES
end

# Application routes preserve the Rails helpers and enforce each document's audience.
Rails.application.config.active_storage.draw_routes = false
Rails.application.config.active_storage.resolve_model_to_route = :rails_storage_proxy
Rails.application.config.active_storage.urls_expire_in = 15.minutes
