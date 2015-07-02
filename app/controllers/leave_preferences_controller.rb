class LeavePreferencesController < ApplicationController
  unloadable
  include LeavesHolidaysLogic
  
  before_action :set_user, :set_leave_preference
  before_filter :authenticate, except: [:show, :notification]
  before_action :set_holidays, only: [:new, :create, :edit, :update]

  def new
  	if @exists
      redirect_to edit_user_leave_preferences_path
    else
  		@preference = LeavesHolidaysLogic.retrieve_leave_preferences(@user)
  	end
  end

  def create
  	@preference = LeavePreference.new(leave_preference_params) unless @exists
    @preference.user_id = @user_pref.id
  	if @preference.save
      event = LeaveEvent.new(user_id: @user.id, event_type: "user_pref_manual_update", comments: "{changed_by: #{User.current.id}, attributes: #{@preference.attributes}}")
      event.save
      flash[:notice] = "Preferences were sucessfully saved for user #{@user_pref.name}"
  		redirect_to edit_user_leave_preferences_path
  	else
  		flash[:error] = "Invalid preferences"
  		redirect_to new_user_leave_preferences_path
  	end
  end

  def show
    render_403 unless LeavesHolidaysLogic.has_right(@user, @user_pref, @preference, :show)
  end

  def edit
  end

  def update
    @preference.user_id = @user_pref.id
  	success = @preference.update(leave_preference_params)
      
    respond_to do |format|
      format.html { 
        if !success 
          flash[:error] = "Invalid preferences"
        else
          event = LeaveEvent.new(user_id: @user.id, event_type: "user_pref_manual_update", comments: "{changed_by: #{User.current.id}, attributes: #{@preference.attributes}}")
          event.save
          flash[:notice] = "Preferences were sucessfully updated for user #{@user_pref.name}"
          redirect_to edit_user_leave_preferences_path
        end
      }
      format.js
    end
  end

  def destroy
    event = LeaveEvent.new(user_id: @user.id, event_type: "user_pref_deleted", comments: "{changed_by: #{User.current.id}, attributes: #{@preference.attributes}}")
    event.save
  	@preference.destroy
  	redirect_to edit_user_leave_preferences_path
  end

  def notification
    @vote_list = LeavesHolidaysLogic.vote_list(@user_pref)
    @manage_list = LeavesHolidaysLogic.manage_list(@user_pref)
  end


private

  def leave_preference_params
  	params.require(:leave_preference).permit(:user_id, :weekly_working_hours, :annual_leave_days_max, :region, :contract_start_date, :extra_leave_days, :is_contractor, :annual_max_comments, :leave_renewal_date)
  end

  def set_user
      @user = User.current
      @user_pref = User.find(params[:user_id])
  end

  def set_holidays
	@regions = LeavesHolidaysLogic.get_region_list
  end

  def set_leave_preference
    @preference = nil
    @preference = LeavePreference.where(user_id: @user_pref.id).first
    @exists = (@preference != nil)
    if @preference == nil
      @preference = LeavesHolidaysLogic.retrieve_leave_preferences(@user)
    end
  end

  def authenticate
    unless LeavesHolidaysLogic.has_right(@user, @user_pref, @preference, params[:action].to_sym)
      redirect_to user_leave_preferences_path
      return
    end
  end
end