class LeaveStatus < ActiveRecord::Base
  unloadable
  
  belongs_to :user
  belongs_to :leave_request

  before_validation :set_user


  enum acceptance_status: { rejected: 0, accepted: 1 }

  validates :user_id, presence: true
  validates :leave_request_id, presence: true
  validates :acceptance_status, presence: true

  attr_accessible :acceptance_status, :leave_request_id, :comments


  private

    def validate_set_acceptance_status
    
    # self.leave_time_am.to_i == 0 ? (am = 0) : (am = 1)
    # self.leave_time_pm.to_i == 0 ? (pm = 0) : (pm = 1)

    # if am == 1 && pm == 0
    #   self.request_type = 0
    # elsif am == 0 && pm == 1
    #   self.request_type = 1
    # elsif am == 1 && pm == 1
    #   self.request_type = 2
    # else
    #   errors.add(:leave_time_am, "is invalid")
    #   errors.add(:leave_time_pm, "is invalid")
    # end
  end

  def set_user
    self.user_id = User.current.id
  end



end
