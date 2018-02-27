class Invoice < ApplicationRecord
  # Changes in invoice_type enum must be reflected on the view new.html.erb
  enum invoice_type: {
    contract: 0,
    traditional_invoice: 1,
    check: 2,
  }

  enum delivery_status: {
    raw_material: 0,
    in_transit: 1,
    delivered: 2,
  }

  enum backoffice_status: {
    registred: 0,
    approved: 1,
    rejected: 2,
    deposited: 3,
  }

  enum sale_status: {
    not_available: 0,
    for_sale: 1,
    bought: 2,
  }

  belongs_to :operation, optional: true
  belongs_to :payer
  belongs_to :seller
  # delegate :seller, to: :operation, allow_nil: true
  belongs_to :order, optional: true
  has_many :rebuys
  has_many :installments, dependent: :destroy
  belongs_to :buyer, class_name: "Client", optional: true
  # We need this line so that we can create invoice forms with installments (reference: https://www.youtube.com/watch?v=pulzZxPkgmE)
  accepts_nested_attributes_for :installments,
                                allow_destroy: true
                                # reject_if: :all_blank
  accepts_nested_attributes_for :payer,
                                allow_destroy: true
  accepts_nested_attributes_for :operation,
                                allow_destroy: true

  # We need this to upload the invoices in xml format
  has_attached_file :xml_file

  # We need this so that the program understands that total_value is a Money object
  monetize :total_value_cents, with_model_currency: :currency


  def self.from_file(file)
    doc = Nokogiri::XML(file.read)
    file.rewind
    invoice = Invoice.new
    invoice = extract_invoice_general_info(doc, invoice)
    invoice = extract_installments(doc, invoice)
    invoice = extract_payer_info(doc, invoice)
    invoice.operation = Operation.new()
    extract_seller_info(doc, invoice)
    return invoice
  end

  def deposit_value
    total_value - gross_interest - iof - iof_ad
  end

  def average_outstanding_days
    average = 0
    installments.each { |i| average += i.outstanding_days }
    average / installments.count
  end


  def interest
    interest = 0
    installments.each do |i|
      interest += i.interest
    end
    return interest
  end

  def ad_valorem
    ad_valorem = 0
    installments.each do |i|
      ad_valorem += i.ad_valorem
    end
    return ad_valorem
  end

  def gross_interest
    interest + ad_valorem
  end

  def gross_interest_percentage
    gross_interest / total_value * 100
  end

  def advalori_fee
    gross_interest * 0.1
  end

  def iof
    iof = 0
    installments.each do |i|
      iof += i.iof
    end
   return iof
  end

  def iof_ad
    0.0038 * total_value
  end

  def test_ar
    number.to_i + 10
  end

  private

  def self.extract_invoice_general_info (doc, invoice)
    invoice.number = doc.search('fat nFat').text.strip
    # delete("\n .")): takes out blanks spaces, points and paragraphs, otherwise Money class will read "1000.00" as 1000 and convert to 10.00
    invoice.total_value = Money.new(doc.search('fat vLiq').text.delete("\n ."))
    return invoice
  end

  def self.extract_installments (doc, invoice)
    doc.search('dup').each do |xml_installments_info|
      i = Installment.new
      i.number = xml_installments_info.search('nDup').text.strip
      # delete("\n .")): takes out blanks spaces, points and paragraphs, otherwise Money class will read "1000.00" as 1000 and convert to 10.00
      i.value = Money.new(xml_installments_info.search('vDup').text.delete("\n ."))
      i.due_date = xml_installments_info.search('dVenc').text.strip
      i.invoice = invoice
      invoice.installments.push(i)
    end
    return invoice
  end

  #TODO: split this method it is too big
  def self.extract_payer_info (doc, invoice)
    doc.search('dest').each do |xml_payer_info|
      identification_number = xml_payer_info.search('CNPJ').text.strip
      if Payer.exists?(identification_number: identification_number)
        payer = Payer.find_by_identification_number(identification_number)
      else
        payer = Payer.new
        payer.identification_number = identification_number
        payer.company_name = xml_payer_info.search('xNome').text.strip
        payer.address = xml_payer_info.search('xLgr').text.strip
        payer.address_number = xml_payer_info.search('nro').text.strip
        payer.neighborhood = xml_payer_info.search('xBairro').text.strip
        payer.city = xml_payer_info.search('xMun').text.strip
        payer.state = xml_payer_info.search('UF').text.strip
        payer.zip_code = xml_payer_info.search('CEP').text.strip
        payer.registration_number = xml_payer_info.search('IE').text.strip
      end
      invoice.payer = payer
      return invoice
    end
  end

  def self.extract_seller_info (doc, invoice)
    doc.search('emit').each do |xml_seller_info|
      identification_number = xml_seller_info.search('CNPJ').text.strip
      if Seller.exists?(identification_number: identification_number)
        seller = Seller.find_by_identification_number(identification_number)
      else
        seller = Seller.new
        seller.identification_number = identification_number
        seller.company_name = xml_seller_info.search('xNome').text.strip
        seller.company_nickname = xml_seller_info.search('xFant').text.strip
      end
      invoice.operation.seller = seller
    end
  end
end
