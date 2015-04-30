module LeavesHolidaysLogic

	def self.issues_list
		Rails.logger.info "IN HELPER ISSUES LIST"
		issues_tracker = RedmineLeavesHolidays::Setting.default_tracker_id
		issues_project = RedmineLeavesHolidays::Setting.default_project_id
		return Issue.where(project_id: issues_project, tracker_id: issues_tracker) #.collect{|t| [t.subject, t.id] }
	end

	def self.roles_list
		Role.find_all_givable.sort.collect{|t| [position: t.position, id: t.id, name: t.name] }
	end

	def self.plugin_admins
		RedmineLeavesHolidays::Setting.plugin_admins.map(&:to_i)
	end

	def self.project_list_for_user(user)
		user.memberships.uniq.collect{|t| t.project_id}
	end

	def self.allowed_roles_for_user_for_project(user, project)
		allowed_roles = user.roles_for_project(project).sort.uniq
		allowed_roles.collect{|r| {position: r.position, allowed: r.allowed_to?(:manage_leaves_requests)}}
	end

	def self.is_allowed_to_view_request(user, user_request)
		return true if user.id == user_request.id
		return true if user.allowed_to?(:view_all_leaves_requests, nil, :global => true) || user.allowed_to?(:manage_leaves_requests, nil, :global => true)
		return true if self.plugin_admins.include?(user.id)
		false
	end

	def self.is_allowed_to_manage_request(user, user_request)
		return true if user.id == user_request.id #Only the creator of the request can change it
		false
	end

	def self.is_allowed_to_view_status(user, user_request)
		return true if user.id == user_request.id #A user can see the status of his own requests
		#A user with this right has access to all the leave request statuses
		return true if user.allowed_to?(:view_all_leaves_requests, nil, :global => true) || user.allowed_to?(:manage_leaves_requests, nil, :global => true)
		return true if self.plugin_admins.include?(user.id) 
		false
	end

	def self.is_allowed_to_manage_status(user, user_request)
		return true if self.plugin_admins.include?(user.id) #A plugin Admin can approve all the requests including his own requests
		return false if !user.allowed_to?(:manage_leaves_requests, nil, :global => true)
		return false if self.plugin_admins.include?(user_request.id) #User req is plugin admin and hence his role >>> user -> Disallow
		return false if user.id == user_request.id #Any non plugin admin cannot approve his own requests

		common_projects = self.project_list_for_user(user) & self.project_list_for_user(user_request)
		if !common_projects.empty?
			common_projects.each do |p|
				project = Project.find(p)
				array_roles_user = self.allowed_roles_for_user_for_project(user, project)
				array_roles_user_req = self.allowed_roles_for_user_for_project(user_request, project)
				array_roles_user.each do |role|
					return true if (role[:position] < array_roles_user_req.first[:position]) && role[:allowed]
				end
			end
			
		end
		false
	end

	def self.can_approve_request(user_request)
		users = User.where(status: 1)
		users = users.collect {|t| {uid: t.id, name: t.name}}

		users.delete_if { |u| 
			uobj = User.find(u[:uid])
			# (!uobj.allowed_to?(:manage_leaves_requests, nil, :global => true)) || (!self.is_allowed_to_manage_status(uobj, user_request))
			!self.is_allowed_to_manage_status(uobj, user_request)
		}
		return users
	end

end