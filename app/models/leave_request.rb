class LeaveRequest < ActiveRecord::Base
  unloadable
  include LeavesHolidaysLogic
  include LeavesHolidaysDates
  include Redmine::Utils::DateCalculation


  default_scope { joins(:user).where(users: {status: 1}).where.not(request_status: "3") }
  
  belongs_to :user
  belongs_to :issue
  has_one :leave_status, dependent: :destroy
  has_many :leave_vote, dependent: :destroy

  before_validation :set_user
  before_validation :set_user_preferences
  before_validation :set_informational
  before_save :validate_days_remaining
  before_update :validate_update
  after_save :send_notifications

  enum request_status: { created: 0, submitted: 1, processed: 2, cancelled: 3, processing: 4 }
  enum request_type: { am: 0, pm: 1, ampm: 2 }

  validates :from_date, date: true, presence: true
  validates :to_date, date: true, presence: true
  validates :user_id, presence: true
  validates :issue_id, presence: true
  validates :request_type, presence: true
  validates :request_status, presence: true

  validates :region, presence: true
  validates :weekly_working_hours, presence: true, numericality: true, inclusion: { in: 0..80}
  validates :annual_leave_days_max, presence: true, numericality: true, inclusion: { in: 0..365}
  validates :is_informational, :inclusion => {:in => [true, false]}

  validates_length_of :comments, :maximum => 255

   validate :validate_set_request_type
   validate :validate_date_period
   validate :validate_issue
   validate :validate_overlaps
   validate :validate_update
   validate :validate_quiet
   validate :validate_days_remaining
   

  attr_accessor :leave_time_am, :leave_time_pm
  attr_accessible :from_date, :to_date, :leave_time_am, :leave_time_pm, :issue_id, :comments, :user_id, :request_type

  scope :for_user, ->(uid) { where(user_id: uid) }

  scope :overlaps, ->(fr, to) { where("(DATEDIFF(from_date, ?) * DATEDIFF(?, to_date)) >= 0", to, fr) }

  scope :created, -> { where(request_status: "0") }

  scope :submitted, -> { where(request_status: "1") }

  scope :processing, -> { where(request_status: "4") }

  scope :processed, -> { where(request_status: "2") }

  scope :cancelled, -> { where(request_status: "3") }

  scope :not_informational, -> { where(is_informational: "0") }

  scope :coming, -> { where("from_date > ?", Date.today) }

  scope :finished, -> { where("to_date < ?", Date.today) }

  scope :ongoing_or_finished, -> { where("from_date <= ? OR to_date <= ?", Date.today, Date.today) }  

  scope :ongoing, -> { where("from_date <= ? AND to_date >= ?", Date.today, Date.today) }

  scope :accepted, -> { processed.includes(:leave_status).where(leave_statuses: { acceptance_status: "1" }) }

  scope :not_rejected, -> { rejected_ids = processed.includes(:leave_status).where(leave_statuses: { acceptance_status: "0" }).pluck("leave_requests.id")
                            where.not(id: rejected_ids) }

  # TO CHECK
  scope :processable_by, ->(user) {
    ids = []

    leave_list = LeaveRequest.where.not(request_status: 0).includes(:user)

    user_list = LeavesHolidaysLogic.users_leave_approval_list(user, leave_list.map(&:user).uniq)

    leave_list.where(user_id: user_list.map(&:id))
  }

  scope :pending_or_accepted, -> { not_rejected.where.not(request_status: "0") }

  # TO CHECK
  scope :viewable_by, ->(uid) {
    user = User.find(uid)
    processed_ids = processed.pluck(:id)
    processed_ids.delete_if { |id| leave = LeaveRequest.find(id) 
                                return !(LeavesHolidaysLogic.has_right(user, leave.user, LeaveRequest, :read, leave))}
    where(id: processed_ids)
  }

  scope :status, lambda {|arg| where(arg.blank? ? nil : {:request_status => arg}) }
  
  scope :reason, lambda {|arg| where(arg.blank? ? nil : {:issue_id => arg}) }

  scope :when, lambda {|arg| 
    return nil if arg.blank?
    arg = [*arg] or Array(arg)
    args = arg.to_a & ['ongoing', 'coming', 'finished']
    return nil if args.count == 3
    ids = []
    args.each do |a|
      ids << LeaveRequest.send(a).pluck(:id)
    end

    ids = ids.flatten.uniq

    where(id: ids)
   }

  scope :not_from_contractors, -> {
    user_list_lp = includes(user: :leave_preference).map(&:user).uniq.keep_if{|u| u.leave_preference }.map(&:id)
    uid_contractors = LeavePreference.where(user_id: user_list_lp, is_contractor: true).pluck(:user_id)
    where.not(user_id: uid_contractors)
  }


  def get_status
    return self.request_status unless self.request_status == "processed"
    return self.leave_status.acceptance_status
  end

  # def get_days(arg)
  #   LeavesHolidaysDates.get_days(arg, self.user, self)
  # end

  def get_days_remaining_with
    remaining = self.user.days_remaining(from_date)
    if !is_actually_deduced? && !is_non_deduce_leave
      remaining -= actual_leave_days
    end
    return remaining
  end

  def get_days_remaining_without
    remaining = self.user.days_remaining(from_date)
    if is_actually_deduced? && !is_non_deduce_leave
      remaining += actual_leave_days
    end
    return remaining
  end

  def updated_on
    return self.updated_at.to_date
  end

  def created_on
    return self.created_at.to_date
  end

  def has_am?
    return self.request_type == "am" || self.request_type == "ampm"
  end

  def has_pm?
    return self.request_type == "pm" || self.request_type == "ampm"
  end

  def half_day?
    return self.request_type != "ampm"
  end

  def get_leave_period
    return self.user.leave_period(self.from_date)
  end

  def in_current_leave_period?
    current_period = self.user.leave_period
    return current_period && current_period == self.get_leave_period
  end

  def real_leave_days
    return 0.5 if half_day?
    return ((to_date - from_date).to_i + 1)
  end

  def actual_leave_days
    return 0.5 if half_day?
    return LeavesHolidaysLogic.get_working_days_count(from_date, to_date, region)
  end

  def leave_days_within(from, to)
    if half_day?
      if (from_date <= to && from <= to_date)
        return 0.5
      else
        return 0.0
      end
    end

    leave_interval = from_date..to_date
    range_interval = from..to

    inters = leave_interval.to_a & range_interval.to_a

    return (inters.max + 1 - inters.min).to_i
  end

  # Triggers approval system
  def is_non_approval_leave
    p = RedmineLeavesHolidays::Setting.defaults_settings(:default_non_approval_issues) || []
    return self.issue_id.to_s.in?(p)
  end

  # Triggers remaining days deducting
  def is_non_deduce_leave
    p = RedmineLeavesHolidays::Setting.defaults_settings(:default_non_deduce_issues) || []
    return self.issue_id.to_s.in?(p)
  end

  # Triggers reduced notifications to only view_all roles
  def is_quiet_leave
    p = RedmineLeavesHolidays::Setting.defaults_settings(:default_quiet_issues) || []
    return self.issue_id.to_s.in?(p)
  end 


  def is_actually_deduced?
    return !self.is_non_deduce_leave && self.get_status.in?(["submitted", "processing", "accepted"])
  end

  def vote_list_left
    @vote_list_left ||= LeavesHolidaysLogic.vote_list_left(self)
  end

  def vote_list
    @vote_list ||= LeavesHolidaysLogic.vote_list(self.user)
  end

  def manage_list
    @manage_list ||= LeavesHolidaysLogic.manage_list(self.user)
  end

  def manage(args = {})
    status = LeaveStatus.where(leave_request_id: self.id).first
    if status != nil
      status.update_attribute(:acceptance_status, args[:acceptance_status])
      status.update_attribute(:comments, args[:comments])
    else
      status = LeaveStatus.new
      status.leave_request = self
      status.acceptance_status = args[:acceptance_status]
      status.comments = args[:comments]
      if status.save
        self.update_attribute(:request_status, "processed")
      end
    end
  end

  def deadline(reg = self.region)
    length = self.actual_leave_days.ceil
    from = self.from_date

    deadline = same_or_previous_working_day(from - length.day, reg)
    return deadline
  end

  def css_classes(manageable=false)
    s = "leave-request reason-#{self.issue_id} type-#{self.request_type}"
    s << ' in-past' if self.to_date < Date.today
    s << ' in-present' if self.to_date >= Date.today && self.from_date <= Date.today
    s << ' in-future' if self.from_date > Date.today
    s << " status-#{self.get_status}"
    s << ' manageable-by-me' if manageable
    s << ' created-by-me' if self.user_id == User.current.id
    s << ' needs-attention' if manageable && self.from_date <= Date.today && self.get_status.in?(["submitted", "processing"])
    return s
  end

  def css_background_color
    Digest::MD5.hexdigest(self.user.login)[0..5]
  end

  def css_style
    hex = css_background_color
    rgb = hex.match(/(..)(..)(..)/).to_a.drop(1).map(&:hex)

    #http://www.w3.org/TR/AERT#color-contrast
    treshold = ((rgb[0] * 299) + (rgb[1] * 587) + (rgb[2] * 114)) / 1000

    font_color = treshold > 125 ? "black" : "white"

    return "background: \##{hex}; color: #{font_color};"
  end

  def self.are_on_leave(user_ids, date = Date.today)
    if !user_ids.is_a?(Array)
      user_ids = [user_ids]
    end
    LeaveRequest.overlaps(date, date).includes(:leave_status).where(user_id: user_ids, :leave_statuses => {:acceptance_status => LeaveStatus.acceptance_statuses["accepted"]}).pluck(:user_id)
  end
    
	private

	def validate_date_period
    if to_date != nil && from_date != nil
  		if to_date < from_date
  			errors.add(:base,"The end of the leave cannot take place before its beginning")
  		end

      if half_day? && (to_date - from_date).to_i > 0
        errors.add(:base,"Half day leaves cannot be more than 1 day")
      end

      # Forbid the leave creation if it's in the past
      # if to_date != nil && from_date != nil && (from_date < Date.today || to_date < Date.today)
      #   errors.add(:base,"Your leave is in the past")
      # end

      #check leave is not in a week-end or bank holiday

      count = 0

      real_leave_days.ceil.times do |i|
        if (from_date + i).holiday?(region.to_sym, :observed) || non_working_week_days.include?((from_date + i).cwday)
          count += 1
        end          
      end

      if count == real_leave_days.ceil
        errors.add(:base,"A leave cannot occur only on bank holiday(s) or non working day(s)")
      end
    end

	end

	def validate_issue
		if issue_id != nil && !((LeavesHolidaysLogic.issues_list(self.user).pluck(:id)).include?(issue_id))
			errors.add(:issue, "is invalid")
		end
	end

  def validate_set_request_type
    
    self.leave_time_am.to_i == 0 ? (am = 0) : (am = 1)
    self.leave_time_pm.to_i == 0 ? (pm = 0) : (pm = 1)

    if am == 1 && pm == 0
      self.request_type = 0
    elsif am == 0 && pm == 1
      self.request_type = 1
    elsif am == 1 && pm == 1
      self.request_type = 2
    else
      errors.add(:leave_time_am, "is invalid")
      errors.add(:leave_time_pm, "is invalid")
    end
  end

  def validate_days_remaining
    if !self.is_non_deduce_leave && self.in_current_leave_period?
      if self.get_days_remaining_with < 0
        drw = self.get_days_remaining_without
        ald = self.actual_leave_days
        errors.add(:base, "You have #{drw} #{'day'.pluralize(drw)} remaining for the current leave period. The current leave request is #{ald} #{'day'.pluralize(ald)} long, hence it cannot be created.")
      end
    end
  end

  def set_user
    self.user_id = User.current.id
  end

  def set_user_preferences
    preferences = self.user.leave_preferences
    
    self.region = preferences.region.to_sym
    self.weekly_working_hours = preferences.weekly_working_hours
    self.annual_leave_days_max = preferences.annual_leave_days_max
  end

  def set_informational
    if self.is_non_deduce_leave
      self.is_informational = 1
    else
      self.is_informational = 0
    end
  end

  def validate_overlaps
    overlaps = LeaveRequest.for_user(self.user_id).overlaps(from_date, to_date).not_rejected.where.not(id: self.id)

    if half_day?
      if overlaps.count > 1
        overlaps.find_each do |p|
          errors.add(:base, "You have a leave overlapping the current one. Id: #{p.id} From: #{p.from_date}, To: #{p.to_date}")
        end
      elsif overlaps.count == 1
        o = overlaps.first
        if !o.half_day? || (o.has_am? && self.has_am?) || (o.has_pm? && self.has_pm?)
          errors.add(:base, "You have a leave overlapping the current one. Id: #{o.id} From: #{o.from_date}, To: #{o.to_date}")
        end
      else

      end
    else
    
      overlaps.created.find_each do |p|
        errors.add(:base, "You have a leave overlapping the current one. Id: #{p.id} From: #{p.from_date}, To: #{p.to_date}")
      end

      overlaps.submitted.find_each do |p|
        errors.add(:base, "You have a leave overlapping the current one. Id: #{p.id} From: #{p.from_date}, To: #{p.to_date}")
      end

      overlaps.processed.find_each do |p|
        LeaveStatus.for_request(p.id).accepted.find_each do |a|
          errors.add(:base, "You have a leave overlapping the current one. Id: #{p.id} From: #{p.from_date}, To: #{p.to_date}") 
        end
      end

    end
  end

  def status
    status = LeaveStatus
  end

  def validate_update
    if LeaveRequest.where(id: self.id).processed.exists?
      errors.add(:base, "You cannot update this leave request as it has already been processed") 
    end
  end

  def validate_quiet
    if self.is_non_approval_leave && self.comments == ""
      errors.add(:comments, "Are mandatory for this leave reason")
    end
  end

  def same_or_previous_working_day(date, region)
      d = date
      while (d).holiday?(region.to_sym, :observed) || non_working_week_days.include?((d).cwday)
        d -= 1.day
      end
      return d
  end

  # TO CHECK
  def send_notifications

    changes = self.changes
    if RedmineLeavesHolidays::Setting.defaults_settings(:email_notification).to_i == 1
      if changes.has_key?("request_status")
        if changes["request_status"][1].in?(["submitted", "created", "cancelled"])
          unless changes["request_status"][0].in?(["created"]) && changes["request_status"][1].in?(["cancelled"])

          user_list = []
          user_list = (self.manage_list + self.vote_list_left).collect{ |e| e.first[:user]}.uniq
          if user_list.empty? || LeavesHolidaysLogic.should_notify_plugin_admin(self.user, 3)
            user_list = user_list + LeavesHolidaysLogic.plugin_admins_users
          end

          user_list = user_list - [self.user]

          case changes["request_status"][1]
          when "submitted"
            Mailer.leave_request_add(user_list, self, {user: self.user}).deliver
          #when "created"
          #  Mailer.leave_request_update(user_list, self, {user: self.user, action: "unsubmitted"}).deliver
          when "cancelled"
            if changes["request_status"][0].in?(["submitted","processing"])
              Mailer.leave_request_update(user_list, self, {user: self.user, action: "cancelled"}).deliver
            end
          else
          end

        end

        end
      end
      
    end
  end
end
