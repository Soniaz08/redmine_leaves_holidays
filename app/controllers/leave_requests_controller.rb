class LeaveRequestsController < ApplicationController
  unloadable
  include LeavesHolidaysLogic
  before_action :set_leave_request, only: [:show, :edit, :update, :destroy, :submit, :unsubmit]
  before_action :set_status, only: [:show]
  before_action :view_request, only: [:show]
  before_action :manage_request, only: [:edit, :update, :destroy]
  before_action :set_issue_trackers
  before_action :set_checkboxes, only: [:edit, :update]
  # before_action :set_approvers, only: [:index]
  def index
    @leave_requests = {}
    @leave_requests['requests'] = LeaveRequest.for_user(User.current.id)#.pending
    # @leave_requests = LeaveRequest.all
  	@leave_requests['approvals'] = LeaveRequest.processable_by(User.current.id)#.pending
  end

  def new
  	@leave = LeaveRequest.new
    # Rails.logger.info "ROLES: #{User.current.projects_by_role.to_yaml}"
  end

  def create
  	@leave = LeaveRequest.new(leave_request_params)    
  	if @leave.save
  		redirect_to @leave
  	else
  		render new_leave_request_path
  	end
  end

  def submit
    unless @leave.request_status == "created" && User.current == @leave.user
      render_403
      return
    else
      @leave.update_attribute(:request_status, "submitted")
      redirect_to @leave
    end
  end

  def unsubmit
    unless @leave.request_status == "submitted" && User.current == @leave.user
      render_403
      return
    else
      @leave.update_attribute(:request_status, "created")
      redirect_to @leave
    end
  end

  def show
  end

  def edit
    render_403 unless @leave.request_status == "created" && User.current == @leave.user
  end

  def update
    # If Leave is updated while already approved, we must restart the approval process ?
    # Or forbid the update ?
    if @leave.update(leave_request_params)
  		redirect_to @leave #:action => 'index'
  	else
  		render :edit
  	end
  end

  def destroy
    #Should not delete the leave request in DB
    #Whatever the status of the leave, should notify the users who were informed of the request creation
    #A leave request which already took place cannot be deleted = Hours won't be deletable.
    @leave.destroy
    redirect_to leave_requests_path
  end

  private

  def set_leave_request
    begin
  	  @leave = LeaveRequest.find(params[:id])
  	rescue ActiveRecord::RecordNotFound
  		render_404
  	end
  end

  def set_status
    if @leave.request_status == "processed"
      @status = LeaveStatus.for_request(@leave.id).first if @status == nil
    end
  end

  def set_checkboxes
  	@leave.leave_time_am = @leave.has_am?
  	@leave.leave_time_pm = @leave.has_pm?
  end

  def set_issue_trackers
  	@issues_trackers = LeavesHolidaysLogic.issues_list if @issues_trackers == nil
  end

  def leave_request_params
  	params.require(:leave_request).permit(:from_date, :to_date, :user_id, :issue_id, :leave_time_am, :leave_time_pm, :comments)
  end

  def view_request
    render_403 unless LeavesHolidaysLogic.is_allowed_to_view_request(User.current, @leave)
  end

  def manage_request
    render_403 unless LeavesHolidaysLogic.is_allowed_to_manage_request(User.current, @leave)
  end

  def set_approvers
    @approvers = LeavesHolidaysLogic.can_approve_request(User.current) if @approvers == nil
  end
end
