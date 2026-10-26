# frozen_string_literal: true

require 'test_helper'

class DocumentScansHelperTest < ActionView::TestCase
  include BadgeHelper

  test 'badge reports the stored scan result and never infers clearance from a file existing' do
    owner = create(:constituent)
    { clean: 'Passed', pending: 'Pending', blocked: 'Blocked', failed: 'Failed', not_scanned: 'Not scanned' }.each do |status, label|
      blob = uploaded_blob
      unless status == :not_scanned
        mark_document_clean!(blob, user: owner)
        DocumentScan.find_by!(blob: blob).update!(status: status, completed_at: status == :pending ? nil : Time.current)
      end

      html = Nokogiri::HTML.fragment(render(partial: 'shared/document_scan_status', locals: { document: blob }))
      badge = html.at_css('[data-testid="document-scan-status"]')
      assert_equal status.to_s, badge['data-scan-status']
      assert_equal ['Virus scan', label], badge.css('span').map(&:text).map(&:strip)
      assert_equal %i[clean blocked failed].include?(status) ? 1 : 0, badge.css('time[datetime]').size
    end
  end

  test 'file groups load scans once across blobs and both attachment wrappers including missing scans' do
    application = create(:application)
    clean = uploaded_blob
    unscanned = uploaded_blob
    mark_document_clean!(clean, user: application.user)
    application.income_proof.attach(clean)
    application.residency_proof.attach(unscanned)
    documents = [clean, application.income_proof, application.income_proof.attachment,
                 unscanned, application.residency_proof, application.id_proof]
    queries = []
    subscriber = lambda do |*args|
      sql = args.last[:sql]
      queries << sql if sql.match?(/\ASELECT .*FROM "document_scans"/m)
    end

    ActiveSupport::Notifications.subscribed(subscriber, 'sql.active_record') do
      preload_document_scans(documents)
      documents.first(3).each { |document| assert_equal 'clean', document_scan_for(document).status }
      documents.last(3).each { |document| assert_nil document_scan_for(document) }
    end

    assert_equal 1, queries.size
  end

  private

  def uploaded_blob
    file_fixture('income_proof.pdf').open do |io|
      ActiveStorage::Blob.create_and_upload!(io: io, filename: 'proof.pdf', content_type: 'application/pdf')
    end
  end
end
