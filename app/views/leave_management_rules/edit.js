$('#ajax-modal').html('<%= escape_javascript(render :partial => 'leave_management_rules/new_modal') %>');
showModal('ajax-modal', '90%');
$('#sender_list_id').html('<%= escape_javascript options_for_select(actor_collection_for_select_options(@project, "sender"), @sender_list_id) %>');
$('#receiver_list_id').html('<%= escape_javascript options_for_select(actor_collection_for_select_options(@project, "receiver"), @receiver_list_id) %>');
$('#sender_exception_id').html('<%= escape_javascript options_for_select(sender_exception_collection_for_select_options(@project), @sender_exception_id) %>');
$('#receiver_exception_id').html('<%= escape_javascript options_for_select(receiver_exception_collection_for_select_options(@project), @receiver_exception_id) %>');