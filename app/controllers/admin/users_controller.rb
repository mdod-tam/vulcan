# frozen_string_literal: true

module Admin
  class UsersController < BaseController
    include ParamCasting
    include UserServiceIntegration
    include PaperQuickCreatePortalMarkers

    DependentSummary = Struct.new(
      :id,
      :name,
      :date_of_birth,
      :city,
      :state,
      :last_app,
      :last_app_status,
      :last_app_date,
      :has_active_app,
      :eligible_date,
      :eligible_now,
      :relationship_types
    )

    VALID_USER_TYPES = {
      'Admin' => 'Users::Administrator',
      'Administrator' => 'Users::Administrator',
      'Evaluator' => 'Users::Evaluator',
      'Constituent' => 'Users::Constituent',
      'Vendor' => 'Users::Vendor',
      'Trainer' => 'Users::Trainer'
    }.freeze

    # Everything the index, show and search views read about a user. Each reflection caches separately, so
    # :guardians is listed beside the join collections that dependent contact resolution does not read.
    USER_PRELOADS = [
      :role_capabilities, :guardians,
      { guardian_relationships_as_guardian: :dependent_user, guardian_relationships_as_dependent: :guardian_user }
    ].freeze

    def index
      if turbo_frame_request_for_search_results?
        handle_search_frame_request
        return
      end

      load_user_metrics

      filtered_scope = apply_user_filters(User.preload(*USER_PRELOADS))
      @pagy, @users = paginate_users(filtered_scope)

      respond_to do |format|
        format.html
        format.json { render json: @users.as_json(only: %i[id first_name last_name email]) }
      end
    end

    private

    def load_user_metrics
      @user_counts_by_role = User.group(:type).count
      @needs_review_count = User.where(needs_duplicate_review: true).count
      @guardian_count = GuardianRelationship.select(:guardian_id).distinct.count
      @dependent_count = GuardianRelationship.select(:dependent_id).distinct.count
      @total_users_count = User.count
    end

    def apply_user_filters(scope)
      result = Users::FilterService.new(scope, params).apply_filters
      if result.success?
        result.data
      else
        Rails.logger.warn 'User filter error'
        scope.order(:type, :last_name, :first_name)
      end
    end

    def paginate_users(scope)
      pagy(scope, items: 25)
    rescue StandardError => e
      Rails.logger.error "Pagination failed: #{e.class.name}"
      [Pagy.new(count: scope.count, page: 1, items: 25), scope.limit(25)]
    end

    def handle_search_frame_request
      @q = params[:q]
      @role_filter = params[:role]
      @frame_id = params[:turbo_frame_id]

      if @q.present?
        @users = users_for_paper_search(@q, @role_filter, limit: 10)
        enhance_constituent_eligibility(@users) if @role_filter == 'constituent'
      else
        @users = []
      end

      render partial: 'admin/users/user_search_results_list', locals: { users: @users, role: @role_filter }
    end

    def turbo_frame_request_for_search_results?
      turbo_frame_request_id&.end_with?('_search_results') ||
        params[:turbo_frame_id]&.end_with?('_search_results')
    end

    public

    def show
      @user = User.preload(*USER_PRELOADS).find(params[:id])
      @contact_delivery_attention = EmailDelivery::Visibility.contact_attention(@user)
      @access_events = Event.where(auditable: @user, action: %w[capability_granted capability_removed]).includes(:user)
                            .order(created_at: :desc, id: :desc).limit(25)
    end

    def edit
      @user = User.find(params[:id])
    end

    def create
      response.headers['Cache-Control'] = 'no-store'
      service = Applications::PaperGuardianQuickCreateService.new(
        attrs: user_create_params.to_h,
        request_params: params,
        admin: current_user,
        submitted_token: params[:identity_review_receipt],
        selected_candidate_id: params[:selected_candidate_id]
      )
      result = Current.set(paper_context: true) { service.call }

      if result.success?
        user = result.data.fetch(:user)
        store_quick_created_portal_user_marker!(user) if result.data[:created]
        return render json: guardian_quick_create_success_payload(user, result.data[:state])
      end

      render partial: 'admin/paper_applications/guardian_review', formats: [:html], content_type: 'text/html',
             locals: { review: service.review, message: result.message, submitted: params },
             status: :unprocessable_content
    end

    def search
      @q = params[:q]
      @role_filter = params[:role]
      @frame_id = params[:frame_id].presence || "#{@role_filter}_search_results"

      @users = if @q.present?
                 users_for_paper_search(@q, @role_filter, limit: 10)
               else
                 []
               end

      enhance_constituent_eligibility(@users) if @role_filter == 'constituent'
      render 'admin/users/search'
    end

    # Access changes answer with Turbo Streams: a confirmation dialog when removing access would strand open
    # work, otherwise the refreshed row and flash. Refusals and stale impact answer 422 so the dialog stays open.
    def update_role
      role_class = role_class_for(params[:role])
      return render_access_refusal("Invalid role specified: '#{params[:role]}'. Please select a valid role.") unless role_class

      change_access(Users::CapabilityWriter::Intent.change_role(role_class))
    end

    def update_capabilities
      capability = params[:capability].to_s
      intent = to_boolean(params[:enabled]) ? Users::CapabilityWriter::Intent.grant(capability) : Users::CapabilityWriter::Intent.revoke(capability)
      change_access(intent)
    end

    # Share User locks with merge. If merge commits first, reject the retired profile.
    # If this edit locks first, merge waits for the updated contact values.
    def update
      @user = User.find(params[:id])

      ActiveRecord::Base.transaction do
        locked_users = User.lock_for_merge_integrity!(@user, current_user)
        locked_user = locked_users.fetch(@user.id)
        locked_actor = locked_users.fetch(current_user.id)

        unless locked_actor.admin? && locked_actor.public_login_active?
          redirect_to admin_user_path(locked_user), alert: 'Your admin session is no longer eligible for this action.'
          raise ActiveRecord::Rollback
        end

        if locked_user.merged?
          redirect_to admin_user_path(locked_user), alert: 'This record is no longer an eligible active record.'
          raise ActiveRecord::Rollback
        end

        @user = locked_user
        if @user.update(admin_user_params)
          AuditEventService.log(
            action: 'user_updated',
            actor: locked_actor,
            auditable: @user,
            metadata: {
              admin_id: locked_actor.id,
              admin_name: locked_actor.full_name
            }
          )
          redirect_to admin_user_path(@user), notice: t('.user_update_pass')
        else
          render :edit, status: :unprocessable_content
          raise ActiveRecord::Rollback
        end
      end
    end

    def destroy_mfa_tokens
      @user = User.find(params[:id])

      if protected_system_user?(@user)
        AuditEventService.log(
          action: 'admin_user_mfa_tokens_blocked',
          actor: current_user,
          auditable: @user,
          metadata: user_audit_metadata(@user).merge(
            admin_id: current_user.id,
            admin_name: current_user.full_name,
            reason: 'system_user'
          )
        )
        redirect_to admin_user_path(@user), alert: 'You cannot delete MFA tokens for the system user.'
        return
      end

      credential_counts = mfa_credential_counts(@user)
      sessions_count = @user.sessions.count

      User.transaction do
        @user.webauthn_credentials.destroy_all
        @user.totp_credentials.destroy_all
        @user.sms_credentials.destroy_all
        @user.sessions.destroy_all

        AuditEventService.log(
          action: 'admin_user_mfa_tokens_deleted',
          actor: current_user,
          auditable: @user,
          metadata: user_audit_metadata(@user).merge(
            admin_id: current_user.id,
            admin_name: current_user.full_name,
            deleted_mfa_credentials: credential_counts,
            deleted_sessions_count: sessions_count
          )
        )
      end

      if credential_counts.values.sum.positive?
        redirect_to admin_user_path(@user), notice: "Deleted MFA tokens for #{@user.full_name}."
      else
        redirect_to admin_user_path(@user), notice: "No MFA tokens were found for #{@user.full_name}."
      end
    end

    def destroy
      @user = User.find(params[:id])

      if protected_system_user?(@user)
        AuditEventService.log(
          action: 'admin_user_deletion_blocked',
          actor: current_user,
          auditable: @user,
          metadata: user_audit_metadata(@user).merge(
            admin_id: current_user.id,
            admin_name: current_user.full_name,
            reason: 'system_user'
          )
        )
        redirect_to admin_user_path(@user), alert: 'You cannot delete the system user.'
        return
      end

      if @user == current_user
        AuditEventService.log(
          action: 'admin_user_deletion_blocked',
          actor: current_user,
          auditable: @user,
          metadata: user_audit_metadata(@user).merge(
            admin_id: current_user.id,
            admin_name: current_user.full_name,
            reason: 'self_deletion'
          )
        )
        redirect_to admin_user_path(@user), alert: 'You cannot delete your own user account.'
        return
      end

      metadata = user_audit_metadata(@user).merge(
        admin_id: current_user.id,
        admin_name: current_user.full_name
      )

      AuditEventService.log(
        action: 'admin_user_deletion_attempted',
        actor: current_user,
        auditable: @user,
        metadata: metadata
      )

      begin
        @user.destroy!
      rescue ActiveRecord::ActiveRecordError => e
        AuditEventService.log(
          action: 'admin_user_deletion_failed',
          actor: current_user,
          auditable: @user,
          metadata: metadata.merge(error_class: e.class.name)
        )

        redirect_to admin_user_path(@user),
                    alert: "Could not delete #{@user.full_name}. The failure was logged for review."
        return
      end

      AuditEventService.log(
        action: 'admin_user_deleted',
        actor: current_user,
        metadata: metadata
      )

      redirect_to admin_users_path, notice: "Deleted user #{metadata[:target_user_name]}."
    end

    def constituents
      @q = params[:q]
      scope = Users::Constituent.joins(:applications)
                                .where(applications: { status: [Application.statuses[:rejected], Application.statuses[:archived]] })
                                .group('users.id')

      if @q.present?
        scope = scope.where("first_name ILIKE :q OR last_name ILIKE :q OR (first_name || ' ' || last_name) ILIKE :q",
                            q: "%#{@q}%")
      end

      @users = scope.order(:last_name)
    end

    def history
      @user = User.find(params[:id])
      @applications = @user.applications.order(application_date: :desc)
    end

    def dependents
      @guardian = User.find(params[:id])
      waiting_period_years = Policy.get('waiting_period_years') || 3
      @dependents = build_dependent_summaries(@guardian, waiting_period_years)

      respond_to do |format|
        format.html { render 'admin/users/dependents' }
        format.json { render json: dependents_json_response(@guardian, waiting_period_years) }
      end
    rescue ActiveRecord::RecordNotFound
      @guardian = nil
      @dependents = []
      respond_to do |format|
        format.html { render 'admin/users/dependents', status: :ok }
        format.json { render json: { guardian_id: nil, dependents: [] }, status: :ok }
      end
    end

    # The latest application can belong to this user or a dependent.
    def last_application_values
      user = User.find(params[:id])

      candidate_apps = Application.where(user_id: [user.id] + user.dependents.pluck(:id))
                                  .order(application_date: :desc)
      last_app = candidate_apps.first

      if last_app
        render json: {
          success: true,
          application_id: last_app.id,
          application_date: last_app.application_date,
          applicant_name: last_app.user&.full_name,
          household_size: last_app.household_size,
          annual_income: last_app.annual_income,
          maryland_resident: last_app.maryland_resident,
          medical_provider_name: last_app.medical_provider_name,
          medical_provider_phone: last_app.medical_provider_phone,
          medical_provider_fax: last_app.medical_provider_fax,
          medical_provider_email: last_app.medical_provider_email
        }
      else
        render json: { success: true, application_id: nil }
      end
    end

    # Adult prefill uses only the applicant's own applications.
    def adult_application_context
      user = User.find_by(id: params[:id])
      return render json: { success: false, error: 'Not found' }, status: :not_found unless user&.paper_applicant_candidate?

      last_app = user.applications.order(application_date: :desc).first
      eligibility = adult_eligibility_context(user, last_app)
      product_names = last_app&.products&.pluck(:name) || []

      render json: {
        success: true,
        user: adult_user_attributes(user),
        last_application_date: last_app&.application_date,
        product_names: product_names,
        **eligibility,
        household_size: last_app&.household_size,
        annual_income: last_app&.annual_income,
        medical_provider_name: last_app&.medical_provider_name,
        medical_provider_phone: last_app&.medical_provider_phone,
        medical_provider_fax: last_app&.medical_provider_fax,
        medical_provider_email: last_app&.medical_provider_email
      }
    end

    private

    def protected_system_user?(user)
      User.normalize_email(user.email) == 'system@mdmat.org'
    end

    def mfa_credential_counts(user)
      {
        webauthn_credentials: user.webauthn_credentials.count,
        totp_credentials: user.totp_credentials.count,
        sms_credentials: user.sms_credentials.count
      }
    end

    def user_audit_metadata(user)
      {
        target_user_id: user.id,
        target_user_name: user.full_name,
        target_user_email: user.email,
        target_user_type: user.type
      }
    end

    def adult_eligibility_context(user, last_app)
      waiting_period = Policy.get('waiting_period_years') || 3
      has_blocking = user.applications.blocking_new_submission.exists?
      eligible_date = last_app ? (last_app.application_date + waiting_period.years) : nil
      within_waiting = eligible_date.present? && eligible_date > Time.current

      ineligibility_reason = if has_blocking
                               'active_application'
                             elsif within_waiting
                               'waiting_period'
                             end

      {
        eligible_now: ineligibility_reason.nil?,
        ineligibility_reason: ineligibility_reason,
        eligible_after: ineligibility_reason == 'waiting_period' ? eligible_date&.to_date : nil
      }
    end

    def adult_user_attributes(user)
      {
        first_name: user.first_name,
        middle_initial: user.try(:middle_initial),
        last_name: user.last_name,
        email: prefill_contact_email(user),
        phone: prefill_contact_phone(user),
        date_of_birth: user.date_of_birth,
        physical_address_1: user.physical_address_1,
        physical_address_2: user.physical_address_2,
        city: user.city,
        state: user.state,
        zip_code: user.zip_code,
        phone_type: user.phone_type,
        communication_preference: user.communication_preference,
        preferred_means_of_communication: user.preferred_means_of_communication,
        locale: user.locale,
        referral_source: user.try(:referral_source)
      }
    end

    def prefill_contact_email(user)
      email = user.email
      return nil if email.blank? || User.system_generated_email?(email)

      email
    end

    def prefill_contact_phone(user)
      phone = user.phone
      return nil if phone.blank? || User.synthetic_dependent_phone?(phone)

      phone
    end

    def guardian_quick_create_success_payload(user, state)
      {
        success: true,
        state: state,
        user: user.as_json(only: %i[id first_name last_name email phone
                                    physical_address_1 physical_address_2 city state zip_code])
      }
    end

    def build_dependent_summaries(guardian, waiting_period_years)
      guardian.dependents.map do |dep|
        last_app = dep.applications.order(application_date: :desc).first
        has_active_app = dep.applications.blocking_new_submission.exists?
        eligible_date = last_app ? (last_app.application_date + waiting_period_years.years) : Time.current
        eligible_now = !has_active_app && eligible_date <= Time.current
        relationship_types = guardian.relationship_types_for_dependent(dep) rescue [] # rubocop:disable Style/RescueModifier

        DependentSummary.new(
          id: dep.id, name: dep.full_name, date_of_birth: dep.date_of_birth,
          city: dep.city, state: dep.state, last_app: last_app,
          last_app_status: last_app&.status, last_app_date: last_app&.application_date,
          has_active_app: has_active_app, eligible_date: eligible_date,
          eligible_now: eligible_now, relationship_types: relationship_types
        )
      end
    end

    def dependents_json_response(guardian, waiting_period_years)
      {
        guardian_id: guardian.id,
        waiting_period_years: waiting_period_years,
        dependents: @dependents.map(&:to_h)
      }
    end

    def users_for_paper_search(query, role_filter, limit: 10)
      if role_filter == 'constituent'
        result = Users::FilterService.new(User.preload(*USER_PRELOADS), q: query, role: nil).apply_filters
        pool = result.success? ? result.data.limit(50).to_a : []
        return [] if pool.empty?

        pool.select(&:paper_applicant_candidate?).first(limit)
      elsif role_filter == 'guardian'
        result = Users::FilterService.new(User.preload(*USER_PRELOADS), q: query, role: nil).apply_filters
        pool = result.success? ? result.data.limit(50).to_a : []
        pool.select(&:paper_guardian_candidate?).first(limit)
      else
        result = Users::FilterService.new(User.preload(*USER_PRELOADS), q: query, role: role_filter).apply_filters
        result.success? ? result.data.limit(limit).to_a : []
      end
    end

    def enhance_constituent_eligibility(users)
      waiting_period = Policy.get('waiting_period_years') || 3
      users.each { |user| decorate_user_eligibility(user, waiting_period) if user.paper_applicant_candidate? }
    end

    def decorate_user_eligibility(user, waiting_period)
      has_blocking_app = user.applications.blocking_new_submission.exists?
      last_app = user.applications.order(application_date: :desc).first
      eligible_date = last_app ? (last_app.application_date + waiting_period.years) : nil
      within_waiting = eligible_date.present? && eligible_date > Time.current

      user.define_singleton_method(:eligible_now) { !has_blocking_app && !within_waiting }
      user.define_singleton_method(:ineligible_reason) do
        if has_blocking_app
          'Has active application'
        elsif within_waiting
          "Applied #{last_app.application_date.strftime('%b %Y')} — eligible after #{eligible_date.to_date.strftime('%b %d, %Y')}"
        end
      end
      user.define_singleton_method(:last_app_date) { last_app&.application_date }
      user.define_singleton_method(:last_received_products) { last_app&.products&.pluck(:name).presence || [] }
    end

    def role_class_for(raw_role)
      name = raw_role.to_s.include?('::') ? VALID_USER_TYPES.values.find { |value| value == raw_role } : VALID_USER_TYPES[raw_role.to_s.classify]
      name&.safe_constantize
    end

    def change_access(intent)
      user = User.find(params[:id])
      result = Users::CapabilityWriter.call(
        actor: current_user, user: user, intent: intent,
        operation_id: params[:operation_id].presence || SecureRandom.uuid, confirmation: params[:confirmation]
      )
      render_access_result(result, intent)
    rescue ActiveRecord::RecordNotFound
      raise
    rescue StandardError => e
      Rails.logger.error "Admin::UsersController access change failed: #{e.class.name}"
      render_access_refusal('The change could not be saved and nothing was changed. Try again.', user: user)
    end

    def render_access_result(result, intent)
      case result.status
      when :confirmation_required then render_access_dialog(result, intent, status: :ok)
      when :stale then render_access_dialog(result, intent, status: :unprocessable_content)
      when :refused then render_access_refusal(result.message, user: result.user)
      else render_access_row(result.user, result.message, :notice, status: :ok)
      end
    end

    def render_access_dialog(result, intent, status:)
      render turbo_stream: turbo_stream.update(
        'staff_access_dialog',
        partial: 'admin/users/staff_access_dialog',
        locals: { result: result, intent: intent, operation_id: params[:operation_id].presence }
      ), status: status
    end

    # A refusal from the open dialog stays in the dialog. Otherwise the row returns to its stored state.
    def render_access_refusal(message, user: nil)
      return render(turbo_stream: turbo_stream.update('staff_access_error', message), status: :unprocessable_content) if params[:confirmation].present?
      return render_access_row(user, message, :alert, status: :unprocessable_content) if user

      flash.now[:alert] = message
      render turbo_stream: turbo_stream.update('flash', partial: 'shared/flash'), status: :unprocessable_content
    end

    def render_access_row(user, message, type, status:)
      user = User.preload(:role_capabilities).find(user.id)
      flash.now[type] = message
      render turbo_stream: [
        turbo_stream.update('flash', partial: 'shared/flash'),
        turbo_stream.replace(helpers.access_dom_id(user, :badges), partial: 'admin/users/access_badges', locals: { user: user }),
        turbo_stream.replace(helpers.access_dom_id(user, :access), partial: 'admin/users/access_cell', locals: { user: user }),
        turbo_stream.update('staff_access_dialog', '')
      ], status: status
    end

    def admin_user_params
      params.expect(
        user: %i[first_name last_name email phone phone_type
                 physical_address_1 physical_address_2 city state zip_code
                 communication_preference newsletter_signup date_of_birth]
      )
    end

    def user_create_params
      # Accept :user-wrapped fields and direct fields for paper guardian creation.
      if params.key?(:user)
        params.expect(
          user: %i[first_name last_name email phone phone_type
                   physical_address_1 physical_address_2
                   city state zip_code date_of_birth
                   communication_preference locale]
        )
      else
        params.permit(
          :first_name, :last_name, :email, :phone, :phone_type,
          :physical_address_1, :physical_address_2,
          :city, :state, :zip_code, :date_of_birth,
          :communication_preference, :locale
        )
      end
    end

    # JavaScript expects errors by field, such as { phone: "Phone is invalid" }.
    def format_validation_errors(errors)
      error_hash = {}

      Array(errors).each do |error_msg|
        next if error_msg.blank?

        field_name = extract_field_from_error(error_msg)

        if error_hash[field_name].present?
          error_hash[field_name] += "; #{error_msg}"
        else
          error_hash[field_name] = error_msg
        end
      end

      error_hash
    end

    # Accepts messages such as "Phone is invalid", "Email can't be blank", and "Failed to create user: Phone must be...".
    def extract_field_from_error(error_msg)
      clean_msg = error_msg.sub(/^Failed to create (user|guardian|dependent):\s*/i, '')

      case clean_msg
      when /^Phone/i then 'phone'
      when /^Email/i then 'email'
      when /^First name/i then 'first_name'
      when /^Last name/i then 'last_name'
      when /^Date of birth/i then 'date_of_birth'
      when /^Physical address/i then 'physical_address_1'
      when /^City/i then 'city'
      when /^State/i then 'state'
      when /^Zip code/i then 'zip_code'
      else
        clean_msg.split.first.downcase.gsub(/[^a-z0-9_]/, '')
      end
    end
  end
end
