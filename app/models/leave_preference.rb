class LeavePreference < ActiveRecord::Base
  unloadable
  include Redmine::Utils::DateCalculation
  include LeavesHolidaysLogic

  # before_validation :set_user

  belongs_to :user
  attr_accessible :weekly_working_hours, :annual_leave_days_max, :region, :user_id, :contract_start_date, :extra_leave_days, :is_contractor,:annual_max_comments,:leave_renewal_date


  validates :weekly_working_hours, presence: true, numericality: true, inclusion: { in: 0..80}
  validates :annual_leave_days_max, presence: true, numericality: true, inclusion: { in: 0..365}
  validates :contract_start_date, presence: true, date: true
  validates :leave_renewal_date, presence: true, date: true

  validates :extra_leave_days, presence: true, numericality: true, inclusion: { in: -365..365}
  validates :region, presence: true
  validates :user_id, presence: true
  validates :is_contractor, :inclusion => {:in => [true, false]}

  validate :validate_region

  scope :for_user, ->(uid) { where(user_id: uid) }

  private

  def default_days_leaves_months
  	return annual_leave_days_max.to_f / 12.0
  end

  def daily_working_hours
    return LeavesHolidaysLogic.user_params(user, :weekly_working_hours).to_f / (7.0 - non_working_week_days.count )
  end

  def validate_region
  	regions = RedmineLeavesHolidays::Setting.defaults_settings(:available_regions)
  	unless regions.include?(self.region)
  		errors.add(:region, "is invalid")
  	end 
  end

end