class Service < ActiveRecord::Base
  validates_uniqueness_of :service_id
  validates_presence_of :plan_id
  validates_presence_of :quota
end
