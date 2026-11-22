# frozen_string_literal: true

module Admin
  module Icanconnect
    class FilingPrepsController < Admin::BaseController
      include PrivateAttachmentStreaming

      before_action :prepare_filing

      def show
        respond_to do |format|
          format.html
          format.csv do
            csv = @prep.csv
            AuditEventService.log(action: 'export_generated', actor: current_user,
                                  metadata: { export_type: 'icanconnect_worksheet', row_count: @prep.rows.size })
            send_data csv, filename: 'icanconnect-review-worksheet.csv', type: 'text/csv', disposition: 'attachment'
          end
          format.zip { send_data ::Icanconnect::DocumentPackage.build(@prep, actor: current_user), filename: 'icanconnect-filing-evidence.zip', type: 'application/zip', disposition: 'attachment' }
        end
      end

      def update
        ::Icanconnect::FilingWriter.new(actor: current_user).mark!(
          selections: selected_rows, period: params[:claim_period], external_reference: params[:external_reference]
        )
        redirect_to admin_icanconnect_filing_prep_path(from: @from, through: @through, view: @view, category: params[:category]), notice: 'Selected costs marked filed.',
                                                                                                                                  status: :see_other
      rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError, DocumentScan::NotCleared => e
        @error = e.is_a?(ActiveRecord::StaleObjectError) ? 'Some costs or documents changed. Review the updated rows before filing.' : e.message
        @prep = build_filing
        restore_selections
        render :show, formats: [:html], status: :unprocessable_content
      end

      private

      def prepare_filing
        @from = params[:from].presence || Date.current.beginning_of_month.iso8601
        @through = params[:through].presence || Date.current.iso8601
        @view = params[:view].presence || 'unclaimed'
        @prep = build_filing
      rescue ArgumentError => e
        @error = e.message
        render :show, formats: [:html], status: :unprocessable_content
      end

      def build_filing
        ::Icanconnect::FilingPrep.new(from: @from, through: @through, view: @view, category: params[:category])
      end

      def selected_rows
        rows = params.permit(rows: %i[key lock_version review_version selected]).fetch(:rows, {}).values
        rows.select { |row| row['selected'] == '1' }.map(&:to_h)
      end

      def restore_selections
        submitted = selected_rows.index_by { |row| row['key'] }
        @selected_keys = @prep.rows.filter_map do |row|
          selected = submitted[row.key]
          next unless selected && row.ready? && !row.claimed? && selected['lock_version'].to_s == row.record.lock_version.to_s &&
                      selected['review_version'] == row.review_version

          row.key
        end
        @selection_notice = 'Changed or incomplete costs were unchecked. Review them and select them again.' if @selected_keys.size < submitted.size
      end
    end
  end
end
