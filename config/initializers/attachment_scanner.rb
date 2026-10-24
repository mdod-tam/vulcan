# frozen_string_literal: true

require Rails.root.join('app/services/attachment_scanner/configuration')
require Rails.root.join('app/services/attachment_scanner/log_subscriber')

asset_build = defined?(Rake.application) && Rake.application.top_level_tasks == ['assets:precompile']
Rails.application.config.x.attachment_scanner = AttachmentScanner::Configuration.load(required: Rails.env.production? && !asset_build)
Rails.event.subscribe(AttachmentScanner::LogSubscriber.new) { |event| event[:name].start_with?('document_scan.') }
