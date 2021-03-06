class InvoicesController < ApplicationController
  def index
    invoices_for_sale = Invoice.for_sale.includes(:seller).to_a
    user_invoices_for_sale = Invoice.for_sale.includes(:seller).where(seller: current_user.client.sellers).to_a
    user_invoices_not_available = Invoice.where("sale_status = ? AND (backoffice_status = ? OR backoffice_status = ?)", 0, 0, 1).where(seller: current_user.client.sellers).to_a
    @user_offered_invoices = user_invoices_for_sale + user_invoices_not_available
    @rejected_invoices = Rejection.includes(:invoice).where(rejector: current_user.client).map(&:invoice)
    @offered_invoices = invoices_for_sale - @rejected_invoices
    @purchased_invoices = Invoice.sold.includes(:seller).where(buyer: current_user.client)
    @sold_invoices = Invoice.sold.includes(:seller).where(seller: current_user.client.sellers)

    # TODO: verificar se há melhora de performance com a linha de código abaixo
    # @purchased_invoices = Invoice.sold.includes(operation: {seller: {client: :user}}).where(buyer: current_user.client)
  end

  def new
    @invoice = Invoice.new
    @invoice.installments.build
    @invoice.build_payer
    @invoice.build_seller
  end

  def show
    @invoice = Invoice.find(params[:id])
    @seller = @invoice.seller
    @payer = @invoice.payer
    @installments = @invoice.installments
    @seller_used_limit = @seller.used_limit
    @seller_used_limit_percentage = @seller_used_limit[:relative] * 100

    @installments_paid_amount = Money.new(@seller.invoices.joins(:installments).where(installments: {paid: true}).sum("value_cents"))
    @installments_paid_quantity = @seller.invoices.joins(:installments).where(installments: {paid: true}).count
    @installments_paid = @seller.invoices.joins(:installments).where(installments: {paid: true}).group_by_month(:due_date, format: "%b %y").sum("value_cents")
    @installments_paid.transform_values! {|monthly_amount| monthly_amount.to_f/100}

    time_range_future = Time.now..(Time.now + 1.year)
    @installments_on_date_amount = Money.new(@seller.invoices.joins(:installments).where(installments: {paid: false, due_date: time_range_future}).sum("value_cents"))
    @installments_on_date_quantity = @seller.invoices.joins(:installments).where(installments: {paid: false, due_date: time_range_future}).count
    @installments_on_date = @seller.invoices.joins(:installments).where(installments: {paid: false, due_date: time_range_future}).group_by_month(:due_date, format: "%b %y").sum("value_cents")
    @installments_on_date.transform_values! {|monthly_amount| monthly_amount.to_f/100}

    time_range_past = (Time.now - 6.years)...(Time.now)
    @installments_overdue_amount = Money.new(@seller.invoices.joins(:installments).where(installments: {paid: false, due_date: time_range_past}).sum("value_cents"))
    @installments_overdue_quantity = @seller.invoices.joins(:installments).where(installments: {paid: false, due_date: time_range_past}).count
    @installments_overdue = @seller.invoices.joins(:installments).where(installments: {paid: false, due_date: time_range_past}).group_by_month(:due_date, format: "%b %y").sum("value_cents")
    @installments_overdue.transform_values! {|monthly_amount| monthly_amount.to_f/100}

    @installments_all_keys = @installments_overdue.merge(@installments_on_date.merge(@installments_paid))
    @installments_all_keys = @installments_all_keys.sort_by {|date, value| Date.strptime(date, "%b %y") }.to_h
    @installments_paid = merge_smaller_hash_into_bigger(@installments_paid, @installments_all_keys)
    @installments_on_date = merge_smaller_hash_into_bigger(@installments_on_date, @installments_all_keys)
    @installments_overdue = merge_smaller_hash_into_bigger(@installments_overdue, @installments_all_keys)

    if request.xhr?
      render layout: false
    end
  end

  def load_invoice_from_xml
    if params[:invoice][:xml_file].present?
      @invoice = Invoice.from_file(params[:invoice][:xml_file])
      render :new
      return
    else
      redirect_to new_invoice_path
    end
  end

  # TODO: refactor with the Invoice class method self.extract_payer_info
  def create

    invoice = Invoice.new(invoice_and_installments_params)

    payer_identification_number = payer_params[:payer_attributes][:identification_number]
    if Payer.exists?(identification_number: payer_identification_number)
      payer = Payer.find_by_identification_number(payer_identification_number)
    else
      payer = Payer.new(payer_params[:payer_attributes])
    end

    seller_identification_number = seller_params[:seller_attributes][:identification_number]
    if Seller.exists?(identification_number: seller_identification_number)
      seller = Seller.find_by_identification_number(seller_identification_number)
    else
      seller = Seller.new(seller_params[:seller_attributes])
      seller.client = current_user.client
    end

    invoice.payer = payer
    invoice.seller = seller
    ActiveRecord::Base.transaction do
      payer.save!
      seller.save!
      invoice.save!
    end

    redirect_to invoices_path
  end

  def checkout
    @invoices = Invoice.find(JSON.parse(params[:invoices_ids]))
  end

  def rejection
    @invoices = Invoice.find(JSON.parse(params[:invoices_ids]))
  end

  def not_available
    @invoices = Invoice.find(JSON.parse(params[:invoices_ids]))
    @invoices.each do |invoice|
      invoice.not_available!
    end
    redirect_to invoices_path
  end

  def available
    @invoices = Invoice.find(JSON.parse(params[:invoices_ids]))
    @invoices.each do |invoice|
      invoice.for_sale!
    end
    redirect_to invoices_path
  end

  def remove
    @invoices = Invoice.find(JSON.parse(params[:invoices_ids]))
    @invoices.each do |invoice|
      invoice.destroy!
    end
    redirect_to invoices_path
  end

  def payment_status

  end

  private

  def merge_smaller_hash_into_bigger(small, big)
    new_hash = {}
    big.each do |key, value|
      new_hash[key] = small[key] ? small[key] : 0
    end
    return new_hash
  end

  def invoice_and_installments_params
    # In the strong parameters we need to pass the attributes of intallments so that the invoice form can understand it
    params
      .require(:invoice)
      .permit(:number, :total_value, :invoice_type, :sale_status, installments_attributes: [:id, :invoice_id, :_destroy, :number, :value, :due_date, :deposit_date])
  end

  def payer_params
    params
      .require(:invoice)
      .permit(payer_attributes: [:company_name, :identification_number, :address, :address_number, :neighborhood, :city, :state, :zip_code, :registration_number])
  end

  def seller_params
    params
      .require(:invoice)
      .permit(seller_attributes: [:company_name, :identification_number, :company_nickname])
  end
end
