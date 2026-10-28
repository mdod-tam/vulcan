# frozen_string_literal: true

require 'test_helper'

class VoucherNotificationsMailerTest < ActionMailer::TestCase
  setup do
    @application = create(:application)
    @user = @application.user
    @voucher = create(:voucher, application: @application, issued_at: 6.months.ago)
    @vendor = create(:vendor, :approved)
    @transaction = create(:voucher_transaction,
                          voucher: @voucher,
                          vendor: @vendor,
                          status: :transaction_completed,
                          amount: 100.00)

    assigned_template = mock('email_template_assigned')
    assigned_template.stubs(:subject).returns('Voucher assigned')
    assigned_template.stubs(:render_subject).returns('Voucher assigned')
    assigned_template.stubs(:enabled?).returns(true)
    assigned_template.stubs(:render).returns(['Voucher assigned', "Text Assigned for voucher #{@voucher.code}"])

    expiring_soon_template = mock('email_template_expiring')
    expiring_soon_template.stubs(:subject).returns('Voucher expiring soon')
    expiring_soon_template.stubs(:render_subject).returns('Voucher expiring soon')
    expiring_soon_template.stubs(:enabled?).returns(true)
    expiring_soon_template.stubs(:render).returns(['Voucher expiring soon', 'Text Your voucher will expire soon.'])

    expired_template = mock('email_template_expired')
    expired_template.stubs(:subject).returns('Voucher expired')
    expired_template.stubs(:render_subject).returns('Voucher expired')
    expired_template.stubs(:enabled?).returns(true)
    expired_template.stubs(:render).returns(['Voucher expired', "Text Expired for voucher #{@voucher.code}"])

    redeemed_template = mock('email_template_redeemed')
    redeemed_template.stubs(:subject).returns('Voucher redeemed')
    redeemed_template.stubs(:render_subject).returns('Voucher redeemed')
    redeemed_template.stubs(:enabled?).returns(true)
    redeemed_template.stubs(:render).returns(['Voucher redeemed', "Text Redeemed for voucher #{@voucher.code}"])

    # Specific .with() calls make each template name resolve to its own mock.

    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_assigned', locale: 'en')
                              .returns(assigned_template)
    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_expiring_soon', locale: 'en')
                              .returns(expiring_soon_template)
    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_expired', locale: 'en')
                              .returns(expired_template)
    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_redeemed', locale: 'en')
                              .returns(redeemed_template)

    Policy.stubs(:get).returns(nil)
    Policy.stubs(:get).with('voucher_validity_period_months').returns(12)
    Policy.stubs(:get).with('minimum_voucher_redemption_amount').returns(10)
    Policy.stubs(:get).with('organization_name').returns('My Org')
  end

  test 'voucher_assigned' do
    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_assigned.deliver_now

    assert_emails 1
    assert_equal ['no_reply@mdmat.org'], email.from
    assert_equal [@user.email], email.to
    assert_equal 'Voucher assigned', email.subject
    assert_includes email.body.to_s, "Text Assigned for voucher #{@voucher.code}"
  end

  test 'missing template logs only the exception class and retains delivery failure' do
    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_assigned', locale: 'en')
                              .raises(ActiveRecord::RecordNotFound, 'private-template-query-value')
    Rails.logger.expects(:error).with('Missing EmailTemplate for voucher_notifications_voucher_assigned: ActiveRecord::RecordNotFound').once

    assert_no_emails do
      error = assert_raises(RuntimeError) do
        VoucherNotificationsMailer.with(voucher: @voucher).voucher_assigned.deliver_now
      end
      assert_equal 'Email template (text format) not found for voucher_notifications_voucher_assigned', error.message
    end
  end

  %w[voucher_assigned voucher_expiring_soon voucher_expired voucher_redeemed].each do |action|
    test "#{action} renders Spanish dates with a real template" do
      @user.update!(locale: :es)
      name = "voucher_notifications_#{action}"
      template = EmailTemplate.find_by(name: name, locale: :es) || create(:email_template, :text, name: name, locale: :es)
      template.update!(syntax: :legacy_percent, subject: 'Fechas del vale', body: '%<expiration_date_formatted>s',
                       variables: { required: ['expiration_date_formatted'], optional: [] })
      VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                                .with(name, locale: 'es')
                                .returns(template)

      email = VoucherNotificationsMailer.with(voucher: @voucher, transaction: @transaction).public_send(action).deliver_now

      assert_equal [@user.email], email.to
      assert_includes email.body.decoded, I18n.l(@voucher.expiration_date.to_date, format: :long, locale: :es)
      assert_not_includes email.body.decoded, I18n.l(@voucher.expiration_date.to_date, format: :long, locale: :en)
    end
  end

  test 'voucher_expiring_soon' do
    rendered_variables = nil
    specific_template = mock('specific_expiring')
    specific_template.stubs(:subject).returns('Voucher expiring soon')
    specific_template.stubs(:render_subject).returns('Voucher expiring soon')
    specific_template.stubs(:enabled?).returns(true)
    specific_template.define_singleton_method(:render) do |**vars|
      rendered_variables = vars
      ['Voucher expiring soon', 'Text Your voucher will expire in 11 days']
    end

    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_expiring_soon', locale: 'en')
                              .returns(specific_template)

    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_expiring_soon.deliver_now

    assert_emails 1
    assert_equal 'Voucher expiring soon', email.subject
    assert_includes email.body.to_s, 'Text Your voucher will expire in 11 days'
    assert_equal @user.full_name, rendered_variables[:vendor_business_name]
    assert_equal rendered_variables[:days_remaining], rendered_variables[:days_until_expiry]
    assert_includes rendered_variables[:status_box_warning_text], 'Voucher Expiring Soon'
    assert_includes rendered_variables[:status_box_info_text], 'Next Step'
    assert_match(/\$\d+/, rendered_variables[:remaining_value_formatted])
    assert_equal '$10.00', rendered_variables[:minimum_redemption_amount_formatted]
  end

  test 'voucher_expiring_soon localizes runtime status text for Spanish templates' do
    @user.update!(locale: 'es')
    rendered_variables = nil
    specific_template = mock('specific_expiring_es')
    specific_template.stubs(:subject).returns('Importante: Su Vale Expirara Pronto')
    specific_template.stubs(:render_subject).returns('Importante: Su Vale Expirara Pronto')
    specific_template.stubs(:enabled?).returns(true)
    specific_template.define_singleton_method(:render) do |**vars|
      rendered_variables = vars
      ['Importante: Su Vale Expirara Pronto', 'Texto de vencimiento del vale']
    end

    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_expiring_soon', locale: 'es')
                              .returns(specific_template)

    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_expiring_soon.deliver_now

    assert_emails 1
    assert_equal 'Importante: Su Vale Expirara Pronto', email.subject
    assert_includes rendered_variables[:status_box_warning_text], 'El vale expirará pronto'
    assert_includes rendered_variables[:status_box_warning_text], 'Su vale vence en'
    assert_includes rendered_variables[:status_box_info_text], 'Siguiente paso'
    assert_includes rendered_variables[:status_box_info_text], 'antes de la fecha de vencimiento'
    assert_includes rendered_variables[:expiration_date_formatted], 'de'
  end

  test 'voucher_expired' do
    email = VoucherNotificationsMailer.with(voucher: @voucher).voucher_expired.deliver_now

    assert_emails 1
    assert_equal 'Voucher expired', email.subject
    assert_includes email.body.to_s, "Text Expired for voucher #{@voucher.code}"
  end

  test 'voucher_redeemed' do
    redeemed_text = "Text Redeemed for voucher #{@voucher.code} at #{@vendor.business_name}"

    specific_redeemed_template = mock('specific_redeemed')
    specific_redeemed_template.stubs(:subject).returns('Voucher redeemed')
    specific_redeemed_template.stubs(:render_subject).returns('Voucher redeemed')
    specific_redeemed_template.stubs(:enabled?).returns(true)
    specific_redeemed_template.stubs(:render).returns(['Voucher redeemed', redeemed_text])

    # Override only the redeemed template stub.
    VoucherNotificationsMailer.any_instance.stubs(:find_text_template)
                              .with('voucher_notifications_voucher_redeemed', locale: 'en')
                              .returns(specific_redeemed_template)

    email = VoucherNotificationsMailer.with(transaction: @transaction).voucher_redeemed.deliver_now

    assert_emails 1
    assert_equal 'Voucher redeemed', email.subject
    assert_includes email.body.to_s, redeemed_text
  end

  test 'voucher redemption follows the second guardians letter preference despite applicant owned email' do
    manager, first_guardian = redemption_guardians(manager_preference: 'letter', first_preference: 'email')
    letter_options = nil
    Letters::TextTemplateToPdfService.expects(:new).with do |**options|
      letter_options = options
      true
    end.returns(mock(queue_for_printing: true))

    assert_no_emails do
      VoucherNotificationsMailer.with(transaction: @transaction).voucher_redeemed.deliver_now
    end

    assert_equal manager, letter_options[:recipient]
    assert_not_equal first_guardian, letter_options[:recipient]
    assert_equal 'es', letter_options[:locale]
    assert_equal @application, letter_options[:application]
    assert_not_includes letter_options[:variables], :application
    assert_equal @user.first_name, letter_options[:variables][:user_first_name]
  end

  test 'voucher redemption uses the applicant owned email and language when the manager chooses email' do
    manager, first_guardian = redemption_guardians(manager_preference: 'email', first_preference: 'letter')
    email = nil

    assert_no_difference 'PrintQueueItem.count' do
      email = VoucherNotificationsMailer.with(transaction: @transaction).voucher_redeemed.deliver_now
    end

    assert_equal [@user.email], email.to
    assert_not_includes email.to, manager.email
    assert_not_includes email.to, first_guardian.email
    assert_equal 'Redemption confirmation', email.subject
    assert_includes email.body.decoded, @transaction.reference_number
  end

  private

  def redemption_guardians(manager_preference:, first_preference:)
    first_guardian = create(:constituent, locale: 'es', communication_preference: first_preference)
    manager = create(:constituent, locale: 'es', communication_preference: manager_preference)
    @user.update!(locale: 'en', communication_preference: 'email', dependent_email: @user.email)
    create(:guardian_relationship, guardian_user: first_guardian, dependent_user: @user)
    create(:guardian_relationship, guardian_user: manager, dependent_user: @user)
    @application.update!(managing_guardian: manager)
    VoucherNotificationsMailer.any_instance.unstub(:find_text_template)
    { 'en' => 'Redemption confirmation', 'es' => 'Confirmación del canje' }.each do |locale, subject|
      create_real_text_email_template(
        name: 'voucher_notifications_voucher_redeemed', locale: locale, subject: subject,
        body: '{{ user_first_name }}: {{ transaction_reference_number }}',
        required: %w[user_first_name transaction_reference_number]
      )
    end
    [manager, first_guardian]
  end
end
