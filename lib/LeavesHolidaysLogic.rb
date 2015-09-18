module LeavesHolidaysLogic
	using LeavesHolidaysExtensions #local patch of user methods 

	def self.issues_list
		issues_tracker = RedmineLeavesHolidays::Setting.defaults_settings(:default_tracker_id)
		issues_project = RedmineLeavesHolidays::Setting.defaults_settings(:default_project_id)
		return Issue.where(project_id: issues_project, tracker_id: issues_tracker)
	end

	def self.roles_list
		Role.find_all_givable.sort.collect{|t| [position: t.position, id: t.id, name: t.name] }
	end

	def self.plugin_admins
		RedmineLeavesHolidays::Setting.defaults_settings(:default_plugin_admins).map(&:to_i)
	end

	def self.plugin_admins_users
		ids = RedmineLeavesHolidays::Setting.defaults_settings(:default_plugin_admins).map(&:to_i)
		return User.find(ids)
	end

	def self.has_manage_rights(user)
		user.allowed_to?(:manage_leave_requests, nil, :global => true)
	end

	def self.has_vote_rights(user)
		user.allowed_to?(:consult_leave_requests, nil, :global => true)
	end

	def self.has_create_rights(user)
		return user.logged? && user.allowed_to?(:create_leave_requests, nil, :global => true)
	end

	def self.has_view_all_rights(user)
		user.allowed_to?(:view_all_leave_requests, nil, :global => true)
	end

	def self.has_manage_user_leave_preferences(user)
		user.allowed_to?(:manage_user_leave_preferences, nil, :global => true) || self.plugin_admins.include?(user.id)
	end

	def self.leave_memberships(user)
		user.memberships
	end

	def self.leave_projects
		Project.active.where.not(id: self.disabled_project_list)
	end

	def self.disabled_project_list
		projs = RedmineLeavesHolidays::Setting.defaults_settings(:default_quiet_projects)
		if projs != nil
			return projs.map(&:to_i)
		else
			return []
		end
	end

	def self.user_has_rights(user, rights)
		if !rights.is_a?(Array)
			rights = [rights]
		end
		rights.each do |right|
			return false if !user.allowed_to?(right, nil, :global => true)
		end
		return true
	end

	def self.user_has_any_manage_right(user)
		return self.has_manage_rights(user) || self.has_vote_rights(user) || self.has_view_all_rights(user) || self.plugin_admins.include?(user.id)
	end

	def self.users_with_create_leave_request(project_list = [])
		user_ids = []
		user_ids.concat(self.plugin_admins)

		# Get roles allowed to
		role_ids = Role.where("permissions LIKE ?", "%:create_leave_requests%").pluck(:id)
		
		# Get disabled project list
		disabled_project_list = Project.where(id: self.disabled_project_list).pluck(:id)
		
		# Get member role ids of roles allowed
		member_role_ids = MemberRole.where(role_id: role_ids).pluck(:id)

		# Get the uniq user ids of corresponding members
		members = Member.includes(:member_roles, :project, :user).where(member_roles: {id: member_role_ids}, users: {status: 1}).where.not(project_id: disabled_project_list)
		members = members.where(project_id: project_list) unless project_list.empty?

		user_ids.concat(members.select(:user_id).distinct.pluck(:user_id))

		return User.where(id: user_ids.uniq).order(:login)
	end

	def self.members_with_any_manage_right_list
		# Get roles allowed to manage
		role_ids = Role.where("permissions LIKE ? OR permissions LIKE ? OR permissions LIKE ?", "%:manage_leave_requests%", "%:consult_leave_requests%", "%:view_all_leave_requests%").pluck(:id)
		
		# Get disabled project list
		disabled_project_list = Project.where(id: self.disabled_project_list).pluck(:id)
		
		# Get member role ids of roles allowed to manage
		member_role_ids = MemberRole.where(role_id: role_ids).pluck(:id)

		# Get the uniq user ids of corresponding members
		return Member.includes(:member_roles, :project, :user).where(member_roles: {id: member_role_ids}, users: {status: 1}).where.not(project_id: disabled_project_list)
	end

	def self.users_rights_list(rights)
		allowed = []
		User.where(status: 1).find_each do |user|
			if self.user_has_rights(user,rights)
				allowed  << user
			end
		end
		return allowed
	end

	def self.project_list_for_user(user)
		user.memberships.uniq.collect{|t| t.project_id}
	end

	def self.allowed_roles_for_user_for_project(user, project)
		allowed = {}
		allowed_roles = user.roles_for_project(project).sort.uniq
		allowed = allowed_roles.collect{|r| { user: user, user_id: user.id, project: project.name, project_id: project.id, name: r.name, position: r.position, manage: r.allowed_to?(:manage_leave_requests), vote: r.allowed_to?(:consult_leave_requests)}}
		return allowed
	end

	def self.allowed_roles_for_user_for_project_mode(user, project, mode)
		allowed = {}
		allowed_roles = user.roles_for_project(project).sort.uniq
		allowed = allowed_roles.collect{|r| { user: user, user_id: user.id, project: project.name, project_id: project.id, name: r.name, position: r.position, manage: r.allowed_to?(:manage_leave_requests), vote: r.allowed_to?(:consult_leave_requests)}}
		allowed.delete_if { |role|
			case mode
			when 1
				 !(role[:vote] || role[:manage])
			when 2
				 !(role[:vote] && !role[:manage])
			when 3
				 !(role[:manage])
			else
			end
		}
		return allowed
	end

	def self.allowed_roles_for_project_mode(project, mode)
		roles = []
		project.members.find_each do |member|
			user = member.user
			#user.roles_for_project(project).sort.uniq
			allowed = self.allowed_roles_for_user_for_project_mode(user, project, mode)
			roles << allowed unless allowed.empty?
		end
		return roles
	end

	def self.get_region_list
		return RedmineLeavesHolidays::Setting.defaults_settings(:available_regions)
	end

	def self.user_params(user, arg)
		prefs = LeavePreference.where(user_id: user.id).first
		return prefs.send(arg) if prefs != nil
		RedmineLeavesHolidays::Setting.defaults_settings(arg)
	end


	def self.allowed_common_project(user, user_request, mode)
		#Modes: 1, 2, 3
		#1 - role has Manage OR Vote
		#2 - role has Vote AND not Manage
		#3 - role has Manage
		roles = []
		role = {}

		common_projects = user.memberships.uniq.map(&:project) & user_request.memberships.uniq.map(&:project)
		if !common_projects.empty?
			common_projects.each do |project|
				unless project.id.in?(LeavesHolidaysLogic.disabled_project_list)
					array_roles_user = (self.allowed_roles_for_user_for_project_mode(user, project, mode))
					array_roles_user_req = user_request.roles_for_project(project).sort.uniq
					unless array_roles_user_req.empty?
						array_roles_user.each do |role|
							if (role[:position] < array_roles_user_req.first[:position])
								roles << role
							end
						end
					end
				end
			end
		end
		return roles
	end

	def self.allowed_common_project_level(user, user_request, mode)
		#Modes: 1, 2, 3
		#1 - role has Manage OR Vote
		#2 - role has Vote AND not Manage
		#3 - role has Manage
		roles = []
		role = {}

		common_projects = user.memberships.uniq.map(&:project) & user_request.memberships.uniq.map(&:project)
		if !common_projects.empty?
			common_projects.each do |project|
				unless project.id.in?(LeavesHolidaysLogic.disabled_project_list)
					array_roles_user_req = user_request.roles_for_project(project).sort.uniq
					unless array_roles_user_req.empty?
						array_roles_user = self.allowed_roles_for_user_for_project_mode(user, project, mode).uniq.sort_by {|hsh| hsh[:position]}.reverse
						is_found = false
						array_roles_user.each do |role|
							if (role[:position] < array_roles_user_req.first[:position])
								# roles << role
								if !is_found
									roles << role
									is_found = true
								else
									if role[:position] == roles.last[:position]
										roles << role
									end
								end
							end
						end
					end
				end
			end
		end
		return roles
	end

	def self.users_allowed_common_project(user_request, mode)

		p_ids = user_request.projects.pluck(:id)

		users_common_ids = self.members_with_any_manage_right_list.includes(:user).where(project_id: p_ids).select(:user_id).distinct.where.not(user_id: 30).pluck(:user_id) - [user_request.id]
		
		allowed = []

		User.where(id: users_common_ids).find_each do |user|
			res = []
			res = self.allowed_common_project(user, user_request, mode)
		 	unless res.empty?
				allowed  << res
			end
		end

		return allowed
	end

	def self.users_allowed_common_project_level(user_request, mode)
		#projects = user_request.memberships.uniq.map(&:project)

		roles = []
		user_request.projects.each do |project|
			unless project.id.in?(LeavesHolidaysLogic.disabled_project_list)
				array_roles_user_req = user_request.roles_for_project(project).sort.uniq
				unless array_roles_user_req.empty?
					is_found = false
					project_roles = self.allowed_roles_for_project_mode(project, mode).flatten.uniq.sort_by {|hsh| hsh[:position]}.reverse

					project_roles.each do |role|
						if (role[:position] < array_roles_user_req.first[:position]) && LeaveRequest.for_user(role[:user_id].to_i).accepted.ongoing.empty?
							if !is_found
								roles << role
								is_found = true
							else
								if role[:position] == roles.last[:position]
									roles << role
								end
							end
						end
					end
				end
			end
		end
		
		out = []
		out_inner = []
		unless roles.empty?
			sorted_users = roles.sort_by { |hsh| hsh[:user_id] }
			ref_uid = sorted_users.first[:user_id]
			sorted_users.each do |u|
				unless ref_uid == u[:user_id]
					ref_uid = u[:user_id]
					out << out_inner unless out_inner.empty?
					out_inner = []
				end
				out_inner << u
			end
			out << out_inner unless out_inner.empty?
		end
		return out
	end

	def self.should_notify_plugin_admin(user_request, mode)
		projects_common = user_request.memberships.uniq.collect {|m| m.project}

		projects_common.each do |project|
			unless project.id.in?(LeavesHolidaysLogic.disabled_project_list)
				allowed_roles = self.allowed_roles_for_project_mode(project, mode)
				return true if !allowed_roles.empty? && allowed_roles.flatten.first[:user_id] == user_request.id
			end
		end
		return false
	end

	def self.has_right(user_accessor, user_owner, object, action, leave_request = nil)

		object_list = [LeavePreference, LeaveRequest, LeaveStatus, LeaveVote]
	 	action_list = [:create, :read, :update, :delete, :cancel, :submit, :unsubmit, :index]

	 	# Rename superfluous actions from controllers
	 	if !action.in?(action_list)
	 		action = :create if action == :new
	 		action = :read if action == :show
	 		# action = :read if action == :index
	 		action = :update if action == :edit 
	 		action = :delete if action == :destroy
	 	end

		raise ArgumentError, 'Argument is not a user' unless user_accessor.is_a?(User)
		raise ArgumentError, 'Argument is not a user' unless user_owner.is_a?(User)
		raise ArgumentError, "Argument is not a leave object: #{object.class}" unless object.class.in?(object_list) || object.in?(object_list)
		raise ArgumentError, 'Argument is not a valid action' unless action.in?(action_list)


		if object == LeavePreference || object.class == LeavePreference
			if action == :cancel
				return false
			else
				if action.in?([:create, :read, :update, :delete])
					if self.plugin_admins.include?(user_accessor.id) || user_accessor.allowed_to?(:manage_user_leave_preferences, nil, :global => true)
						return true
					else
						if action == :read
							if user_accessor.id == user_owner.id || !self.allowed_common_project(user_accessor, user_owner, 1).empty?
								return true
							end
						end
					end	
				end
			end
		end

		if object == LeaveRequest || object.class == LeaveRequest
			if leave_request == nil
				leave = object
			else
				leave = leave_request
			end
			if action == :create
				return self.has_create_rights(user_accessor)
			end
			# return true if action == :create
			# return false if leave.request_status == "cancelled"
			if action == :index
				return true if self.has_create_rights(user_accessor)
			end
			if action == :read
				return false unless self.has_create_rights(user_accessor)
				return true if user_accessor.id == user_owner.id
				if leave.request_status.in?(["submitted", "processing", "processed"])
					if self.plugin_admins.include?(user_accessor.id) || !self.allowed_common_project(user_accessor, user_owner, 1).empty?
						return true
					else
						if leave.request_status == "processed"
							return true if user_accessor.allowed_to?(:view_all_leave_requests, nil, :global => true)
						end
					end
				else
					return true if user_accessor.allowed_to?(:view_all_leave_requests, nil, :global => true) || self.plugin_admins.include?(user_accessor.id) || !self.allowed_common_project(user_accessor, user_owner, 1).empty?
				end
			end
			if user_accessor.id == user_owner.id
				if action == :update || action == :submit
					return true if leave.request_status == "created"
				end
				if action == :delete
					return true
				end
				if action == :unsubmit
					return true if leave.request_status == "submitted"
				end
			end
		end
		if object == LeaveVote || object.class == LeaveVote
			vote = object
			if (defined?(vote.leave_request)).nil?
				leave = leave_request
			else
				leave = vote.leave_request
			end
			return false if leave.user_id == user_accessor.id

			if action == :create
				if leave.request_status.in?(["submitted", "processing"])
					return true if !self.allowed_common_project(user_accessor, user_owner, 2).empty?
				end
			end
			if leave.request_status.in?(["processing", "processed"])
				if action.in?([:read,:index])
					if self.plugin_admins.include?(user_accessor.id)
						return true
					end
					if !self.allowed_common_project(user_accessor, user_owner, 2).empty?
						return true
					end
					if !self.allowed_common_project(user_accessor, user_owner, 3).empty?
						return true
					end
				end
				if action == :update && leave.request_status == "processing"

					return true if user_accessor.id == user_owner.id# && !self.allowed_common_project(user_accessor, user_owner, 2).empty?
				end
			end
		end
		if object == LeaveStatus || object.class == LeaveStatus
			status = object
			if (defined?(status.leave_request)).nil?
				leave = leave_request
			else
				leave = status.leave_request
			end
			# return true if user_accessor.id == user_owner.id && self.user_params(user_accessor, :is_contractor)
			if action == :create
				if leave.request_status.in?(["submitted", "processing"])
					return true if self.plugin_admins.include?(user_accessor.id) || !self.allowed_common_project(user_accessor, user_owner, 3).empty?
				end
			end
			if leave.request_status == "processed"
				if action.in?([:read, :update, :index])
					return true if self.plugin_admins.include?(user_accessor.id)
					return true if !self.allowed_common_project(user_accessor, user_owner, 3).empty?
				end
				if action == :read
					return true if user_accessor.id == user_owner.id
					return true if user_accessor.allowed_to?(:view_all_leave_requests, nil, :global => true)
				end
			end
		end
		return false
	end

	def self.has_rights(user_accessor, user_owner, objects, actions, leave_request = nil, criteria)
		if !objects.is_a?(Array)
			objects = [objects]
		end

		objects.each do |object|
			actions.each do |action|
				return true if criteria == :or && self.has_right(user_accessor, user_owner, object, action, leave_request)
				return false if criteria == :and && !self.has_right(user_accessor, user_owner, object, action, leave_request)
			end
		end
		return false if criteria == :or
		return true if criteria == :and
	end

	def self.vote_list_left(leave_request)
		list = LeavesHolidaysLogic.users_allowed_common_project(leave_request.user, 2)
		if leave_request == nil
			return list
		else
			list.delete_if { |u| !LeaveVote.for_request(leave_request.id).for_user(u.first[:user_id]).empty? }
		end
		return list
	end

	def self.vote_list(user)
		return LeavesHolidaysLogic.users_allowed_common_project(user, 2)
	end	

	def self.manage_list(user)
		return LeavesHolidaysLogic.users_allowed_common_project_level(user, 3)
	end

	def self.retrieve_leave_preferences(user)
    p = LeavePreference.new
    p.weekly_working_hours = RedmineLeavesHolidays::Setting.defaults_settings(:weekly_working_hours)
    p.annual_leave_days_max = RedmineLeavesHolidays::Setting.defaults_settings(:annual_leave_days_max)
    p.region = RedmineLeavesHolidays::Setting.defaults_settings(:region)
    p.contract_start_date = RedmineLeavesHolidays::Setting.defaults_settings(:contract_start_date)
    p.extra_leave_days = 0.0
    p.is_contractor = RedmineLeavesHolidays::Setting.defaults_settings(:is_contractor)
    p.user_id = user.id
    p.annual_max_comments = ""
    p.leave_renewal_date = RedmineLeavesHolidays::Setting.defaults_settings(:leave_renewal_date)
    return p
  end

  def self.leave_for_project(project)
  	user_ids = project.members.pluck(:user_id)
  	LeaveRequest.where(user_id: user_ids).not.created
  end

  def self.leave_on_for_project(day, project)
  	list = []

  	members = []

		users = project.members.includes(:user).map(&:user)

  	users.each do |user|
			leave = LeaveRequest.for_user(user.id).overlaps(day,day).find_each do |l|
				list << l unless l.get_status.in?(["created","cancelled","rejected"])
			end
		end
		return list
  end

  def self.week_period_from_date(date)
  	hsh = {}
  	day_count = date.cwday
  	hsh[:start_date] = date - (day_count - 1)
  	hsh[:end_date] = hsh[:start_date] + 6
  	return hsh
  end

  # returns only users from user_list that user_accessor can see in leave approval list
  def self.users_leave_approval_list(user_accessor, users_list)
  	out_list = []

  	# get uniq users from list
  	users_list = users_list.uniq
  	return users_list if self.plugin_admins.include?(user_accessor.id) || self.has_view_all_rights(user_accessor)

  	# Remove user accessor if it was in the list as user_accessor is not admin or can't view all requests
  	users_list -= [user_accessor]

  	# user_accessor cannot manage anything if he has'nt a manage right
  	return [] unless self.user_has_any_manage_right(user_accessor)

  	# Parse all leave projects from the user_list provided
  	users_list_projects = self.leave_projects.joins(:memberships).where(:members => { user_id: users_list.map(&:id) }).uniq
  	

  	user_accessor_projects_req = LeavesHolidaysLogic.members_with_any_manage_right_list.where(user_id: user_accessor.id)

  	# Get user_accessor projects where he has a manage right
  	user_accessor_projects = user_accessor_projects_req.map(&:project)

  	# Get common project between both lists
  	common_projects = users_list_projects & user_accessor_projects

  	# Return empty list if no projects are in common
  	return [] if common_projects.empty?
  	#users_list.delete_if { |user_owner| self.allowed_common_project(user_accessor, user_owner, 3).empty? }

  	# Parse each common project
  	common_projects.each do |project|

  		# Get member associated to user_accessor for the given project
  		member_accessor = user_accessor_projects_req.find_by(project_id: project.id)
  		roles_accessor = member_accessor.roles.order(:position)

  		# get members from this project associated to users_list
  		members_list = Member.where(project_id: project.id, user_id: users_list.map(&:id)).includes(:roles, :user).order('roles.position')

  		members_list.each do |member|
  			roles_accessor.each do |role|
  				if role.position < member.roles.first.position
  					out_list << member.user
  					users_list -= [member.user]
  				end
  			end
  		end
  	end

  	return out_list
  end

end