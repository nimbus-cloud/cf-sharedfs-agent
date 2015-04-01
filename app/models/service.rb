class Service < ActiveRecord::Base
  validates_uniqueness_of :service_id
  validates_presence_of :plan_id
  validates_presence_of :quota
  validates_presence_of :username
  validates_presence_of :uid
  validates_presence_of :gid
end
