class Encounter < ActiveRecord::Base
  set_table_name :encounter
  set_primary_key :encounter_id
  include Openmrs
  has_many :observations, :dependent => :destroy, :conditions => {:voided => 0}
  has_many :drug_orders,  :through   => :orders,  :foreign_key => 'order_id'
  has_many :orders, :dependent => :destroy, :conditions => {:voided => 0}
  belongs_to :type, :class_name => "EncounterType", :foreign_key => :encounter_type, :conditions => {:retired => 0}
  belongs_to :provider, :class_name => "Person", :foreign_key => :provider_id, :conditions => {:voided => 0}
  belongs_to :patient, :conditions => {:voided => 0}

  # TODO, this needs to account for current visit, which needs to account for possible retrospective entry
  named_scope :current, :conditions => 'DATE(encounter.encounter_datetime) = CURRENT_DATE()'

  def before_save
    self.provider = User.current.person if self.provider.blank?
    # TODO, this needs to account for current visit, which needs to account for possible retrospective entry
    self.encounter_datetime = Time.now if self.encounter_datetime.blank?
  end

  def after_save
    self.add_location_obs
  end

  def after_void(reason = nil)
    self.observations.each do |row| 
      if not row.order_id.blank?
        ActiveRecord::Base.connection.execute <<EOF
UPDATE drug_order SET quantity = NULL WHERE order_id = #{row.order_id};
EOF
      end rescue nil
      row.void(reason) 
    end rescue []

    self.orders.each do |order|
      order.void(reason) 
    end
  end

  def name
    self.type.name rescue "N/A"
  end

  def encounter_type_name=(encounter_type_name)
    self.type = EncounterType.find_by_name(encounter_type_name)
    raise "#{encounter_type_name} not a valid encounter_type" if self.type.nil?
  end

  def to_s
    if name == 'REGISTRATION'
      "Patient was seen at the registration desk at #{encounter_datetime.strftime('%I:%M')}" 
    elsif name == 'TREATMENT'
      o = orders.collect{|order| order.to_s}.join("\n")
      o = "No prescriptions have been made" if o.blank?
      o
    elsif name == 'VITALS'
      temp = observations.select {|obs| obs.concept.concept_names.map(&:name).include?("TEMPERATURE (C)") && "#{obs.answer_string}".upcase != 'UNKNOWN' }
      weight = observations.select {|obs| obs.concept.concept_names.map(&:name).include?("WEIGHT (KG)") || obs.concept.concept_names.map(&:name).include?("Weight (kg)") && "#{obs.answer_string}".upcase != '0.0' }
      height = observations.select {|obs| obs.concept.concept_names.map(&:name).include?("HEIGHT (CM)") || obs.concept.concept_names.map(&:name).include?("Height (cm)") && "#{obs.answer_string}".upcase != '0.0' }
      vitals = [weight_str = weight.first.answer_string + 'KG' rescue 'UNKNOWN WEIGHT',
                height_str = height.first.answer_string + 'CM' rescue 'UNKNOWN HEIGHT']
      temp_str = temp.first.answer_string + '°C' rescue nil
      vitals << temp_str if temp_str                          
      vitals.join(', ')
    else  
      observations.collect{|observation| "<b>#{(observation.concept.concept_names.last.name) rescue ""}</b>: #{observation.answer_string}"}.join(", ")
    end  
  end
  
  def self.statistics_simplified(encounter_types)
    return_hash = {'me' => {},'today' => {}, 'year' => {}, 'ever' => {}}
    me_hash = {}
    today_hash = {}
    year_hash = {}
    ever_hash = {}
    
    encounter_types.each do |et|
      me_hash[:"#{et}"] = 0
      today_hash[:"#{et}"] = 0
      year_hash[:"#{et}"] = 0
      ever_hash[:"#{et}"] = 0
    end
    
    encounters = Encounter.find_by_sql("SELECT * FROM main_dashboard_patients")
       
    encounters.partition {|e| (e.encounter_datetime.to_datetime >= Date.today.strftime('%Y-%m-%d 00:00:00')) && 
                                                 (e.encounter_datetime.to_datetime <= Date.today.strftime('%Y-%m-%d 23:59:59')) && 
                                                 (e.creator == current_user.user_id) }.first.group_by(&:name).each do |et, dt|
                                                   me_hash[:"'#{et}'"] = dt.count                                                  
                                                 end
   
    encounters.partition {|e| (e.encounter_datetime.to_datetime >= Date.today.strftime('%Y-%m-%d 00:00:00')) && 
                                                 (e.encounter_datetime.to_datetime <= Date.today.strftime('%Y-%m-%d 23:59:59')) }.first.group_by(&:name).each do |et, dt|
                                                   today_hash[:"'#{et}'"] = dt.count                                                  
                                                 end
    encounters.partition {|e| (e.encounter_datetime.to_datetime >= Date.today.strftime('%Y-01-01 00:00:00')) && 
                                                 (e.encounter_datetime.to_datetime <= Date.today.strftime('%Y-12-31 23:59:59'))  }.first.group_by(&:name).each do |et, dt|
                                                   year_hash[:"'#{et}'"] = dt.count                                                  
                                                 end
   
    encounters.group_by(&:name).each do |et, dt|
                                       ever_hash[:"'#{et}'"] = dt.count                                                  
                                     end
    return_hash[:'me'] = me_hash
    return_hash[:'today'] = today_hash
    return_hash[:'year'] = year_hash
    return_hash[:'ever'] = ever_hash
    
    return return_hash
  end

  def self.statistics(encounter_types, conds)
    encounter_types = EncounterType.all(:conditions => ['name IN (?)', encounter_types])

    encounter_types_hash = encounter_types.inject({}) {|result, row| result[row.encounter_type_id] = row.name; result }

    if conds
      rows = Encounter.find_by_sql("SELECT count(*) as number, encounter_type 
                                    FROM main_dashboard_patients mdp
                                    WHERE #{conds} 
                                    GROUP BY mdp.encounter_type") 
    else
      rows = Encounter.find_by_sql("SELECT count(*) as number, encounter_type 
                                    FROM main_dashboard_patients mdp
                                    GROUP BY mdp.encounter_type")
    end     

    return rows.inject({}) {|result, row| result[encounter_types_hash[row['encounter_type']]] = row['number']; result }
  end
end
