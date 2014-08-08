%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Marc A. Paradise <marc@getchef.com>
%% Copyright Chef Software, Inc. All Rights Reserved.
%%
%% Common functions for managing user-org associations.
%%

-module(oc_chef_associations).

-include_lib("chef_wm/include/chef_wm.hrl").
-include_lib("oc_chef_wm/include/oc_chef_wm.hrl").
-include_lib("oc_chef_authz/include/oc_chef_authz.hrl").

-export([deprovision_removed_user/3,
         provision_associated_user/3]).

-type deprovision_error() :: error_fetching_usag | error_fetching_org_users_group |
                              error_removing_from_org_user_group.
-type deprovision_warning() :: usag_record_delete_failed | org_admin_group_fetch_failed |
                              org_admin_ace_removal_failed.
-type deprovision_error_tuple() :: {error, { deprovision_error(),term()}}.
-type deprovision_warning_msg() ::  { deprovision_warning(), term() }.
-type deprovision_warning_tuple() :: {warning, [ deprovision_warning_msg() ] }.
-type deprovision_response() ::  ok | deprovision_warning_tuple() | deprovision_error_tuple().

-type provision_error() :: usag_authz_creation_failed | usag_creation_failed |
                           usag_update_failed | add_usag_to_org_users_group_failed | add_user_to_usag_failed.
-type provision_warning() :: fetch_org_admins_failed | add_read_ace_for_admins_failed.
-type provision_error_tuple() :: {error, { provision_error(), term()}}.
-type provision_warning_msg() :: { provision_warning(), term() }.
-type provision_warning_tuple() :: { warning, [ provision_warning_msg() ] }.
-type provision_response() :: ok | provision_warning_tuple() | provision_error_tuple().

% Internal use
-record(context, { authz_context,
                   db_context,
                   org_name,
                   org_id,
                   user_authz_id,
                   user_name,
                   user_id,
                   requestor_authz_id,
                   org_users,
                   msg = [],
                   usag} ).

%% Given a user whose record has been removed from an organization,
%% remove all permissions related to that org, for that user.
%% -  fetch usag
%% 0. fetch org users
%% 1. remove USAG from org users
%% 2. delete USAG
%% 3. remove admin from user read ACE
-spec deprovision_removed_user(#base_state{}, #chef_user{}, oc_authz_id()) ->
    deprovision_response().
deprovision_removed_user(State, User, RequestorAuthzId) ->
    Context = association_context(State, User, RequestorAuthzId),
    Result = chef_db:fetch(#oc_chef_group{org_id = Context#context.org_id,
                                          name = Context#context.user_id},
                           Context#context.db_context),
    deprovision_process_usag(Result, Context).

deprovision_process_usag({ok, USAG}, #context{ db_context = DbContext, org_id = OrgId } = Context) ->
    Result = chef_db:fetch(#oc_chef_group{org_id = OrgId, name = "users"}, DbContext),
    deprovision_remove_usag_from_users(Result, Context#context{usag = USAG});
deprovision_process_usag(Error, _Context) ->
    {error, {error_fetching_usag,Error}}.

deprovision_remove_usag_from_users({ok, OrgUsersGroup}, #context{usag = USAG,
                                                        db_context = DbContext,
                                                        requestor_authz_id = RequestorAuthzId} = Context) ->
    OrgUsersGroup1 = oc_chef_group:remove_group_member(OrgUsersGroup, USAG#oc_chef_group.name),
    Result = chef_db:update(OrgUsersGroup1, DbContext, RequestorAuthzId),
    deprovision_delete_usag(Result, Context#context{org_users = OrgUsersGroup1});
deprovision_remove_usag_from_users(Error, _Context) ->
    {error, {error_fetching_org_users_group, Error}}.

deprovision_delete_usag({ok, _}, #context{usag = USAG, db_context = DbContext } = Context) ->
    % TODO this usag entity will still exist in bifrost
    Result = chef_db:delete_object(USAG, DbContext),
    deprovision_fetch_org_global_admins(Result, Context);
deprovision_delete_usag(Error, _Context) ->
    {error, {error_removing_from_org_user_group, Error}}.

deprovision_fetch_org_global_admins({ok, _}, #context{authz_context = AuthzContext,
                                                      org_name = OrgName} = Context) ->
    Result = oc_chef_authz_db:fetch_global_group_authz_id(AuthzContext, OrgName, "admins"),
    deprovision_remove_global_org_admin_ace(Result, Context) ;
deprovision_fetch_org_global_admins(Error, Context) ->
    % TODO confirm the truth of this:
    % Just for documentation. We don't care if we failed to delete the actual USAG record from
    % the DB. If previous step to remove USAG from org users was successful, we can consider this a
    % successful deletion.
    % This will change when we start doing proper cleanup of auth entity as part of USAG deletion.
    deprovision_remove_global_org_admin_ace({ok, ok}, Context = #context{msg = [{usag_record_delete_failed, Error}]}).

deprovision_remove_global_org_admin_ace({ok, OrgGlobalAdminsAuthzId},
                                        #context{ user_authz_id = UserAuthzId} = Context) ->
    %We're spoofing the requesting actor for this next operation to be the actual user
    % who is being removed.  This is because the actor will need to have update access
    % to that user's record - and the originator of this request may not.
    Result = oc_chef_authz:remove_ace_for_entity(UserAuthzId,
                                                 group, OrgGlobalAdminsAuthzId,
                                                 object, UserAuthzId,
                                                 read),
    deprovision_removed_user_done(Result, Context);
deprovision_remove_global_org_admin_ace(Error, #context{msg = Msg}) ->
    % Here, we have deleted user from the org, etc - but we can't remove permissions.
    % This shouldn't fail the delete request which has already succeeded.
    {warning, [{org_admin_group_fetch_failed, Error}] ++ Msg}.

deprovision_removed_user_done(ok, #context{msg = []}) ->
    ok;
deprovision_removed_user_done(ok, #context{msg = Msg}) ->
    {warning, Msg};
deprovision_removed_user_done(Error, #context{msg = Msg} = Context) ->
    deprovision_removed_user_done(ok, Context#context{msg = [{org_admin_ace_removal_failed, Error}] ++ Msg}).




%% Given a user who has a record within an organization,
%% provision that user with proper permissions. These steps are broken out
%% below as follows:
%% -. create USAG authzd
%% 0. save USAG record
%% 1. update USAG to contain user
%% 2. add USAG to org
%% 3. set org admin read ACL on user (not usag)
-spec provision_associated_user(#base_state{}, #chef_user{}, binary()) -> provision_response().
provision_associated_user(State, #chef_user{id = UserId} = User, RequestorAuthzId) ->
    Context = association_context(State, User, RequestorAuthzId),
    % TODO user superuser for requestorauthzid , per latest oc-account updates
    OrgId = Context#context.org_id,
    USAG0 = oc_chef_group:create_record(OrgId, UserId, RequestorAuthzId),
    Result = oc_chef_authz:create_entity_if_authorized(Context#context.org_id,
                                                       OrgId,
                                                       RequestorAuthzId, group),
    provision_process_usag_authzid(Result, Context#context{usag = USAG0}).

provision_process_usag_authzid({ok, AuthzId}, #context{usag = USAG,
                                                       requestor_authz_id = RequestorAuthzId,
                                                       db_context = DbContext} = Context) ->
    USAG0 = USAG#oc_chef_group{authz_id = AuthzId},
    Result = chef_db:create(USAG0, DbContext, RequestorAuthzId),
    provision_process_usag(Result, Context#context{usag = USAG0});
provision_process_usag_authzid(Error, _Context) ->
    % TODO: After we begin performing this action as superuser,
    % the only error path (forbidden) should not be possible
    {error, {usag_authz_creation_failed, Error}}.

provision_process_usag(ok, #context{usag = USAG,
                                    user_name = UserName,
                                    requestor_authz_id = RequestorAuthzId,
                                    db_context = DbContext} = Context) ->
    USAG0 = USAG#oc_chef_group{users = [UserName]},
    Result = chef_db:update(USAG0, DbContext, RequestorAuthzId),
    provision_add_usag_to_org_users(Result, Context#context{usag = USAG0});
provision_process_usag(Error, _Context) ->
    {error, {usag_creation_failed, Error}}.

provision_add_usag_to_org_users(ok, #context{usag = USAG,
                                        org_id = OrgId,
                                        requestor_authz_id = RequestorAuthzId,
                                        db_context = DbContext} = Context) ->

    {ok, OrgUsersGroup} = chef_db:fetch(#oc_chef_group{org_id = OrgId, name = "users"}, DbContext),
    #oc_chef_group{ groups = Groups } = OrgUsersGroup,
    OrgUsersGroup0 = OrgUsersGroup#oc_chef_group{groups = USAG#oc_chef_group.name ++ Groups},
    Result = chef_db:update(OrgUsersGroup0, DbContext, RequestorAuthzId),
    provision_fetch_org_global_admins(Result, Context);
provision_add_usag_to_org_users(Error, _Context) ->
    {error, {add_user_to_usag_failed, Error}}.

provision_fetch_org_global_admins(ok, #context{org_name = OrgName,
                                        authz_context = AuthzContext } = Context) ->
    Result = oc_chef_authz_db:fetch_global_group_authz_id(AuthzContext, OrgName, "admins"),
    provision_add_user_ace_to_global_admins(Result, Context);
provision_fetch_org_global_admins(Error, _Context) ->
    {error, {add_usag_to_org_users_group_failed, Error}}.

provision_add_user_ace_to_global_admins({ok, OrgGlobalAdminsAuthzId}, #context{user_authz_id = UserAuthzId } = Context) ->
    % Spoofing to user as requestor, so that we have necessary access to update
    Result = oc_chef_authz:add_ace_for_entity(UserAuthzId,
                                                 group, OrgGlobalAdminsAuthzId,
                                                 object, UserAuthzId,
                                                 read),
    provision_associated_user_done(Result, Context);
provision_add_user_ace_to_global_admins(Error, _) ->
    % No need to continue - if we can't get the admin group, we can't add
    % permissions.
    {warning, [{fetch_org_admins_failed, Error}]}.

provision_associated_user_done(ok, _Context) ->
    ok;
provision_associated_user_done(Error, _Context) ->
    {warning, [{add_read_ace_for_admins_failed, Error}]}.


% Consolidate our disparate inputs into one structure for ease of reference
association_context(#base_state{ organization_name = OrgName,
                                 organization_guid = OrgId,
                                 chef_authz_context = AuthzContext,
                                 chef_db_context = DbContext},
                    #chef_user{ authz_id = UserAuthzId,
                                username = UserName,
                                id = UserId },
                    RequestorAuthzId) ->
    #context{ authz_context = AuthzContext,
              db_context = DbContext,
              org_name = OrgName,
              org_id = OrgId,
              user_authz_id = UserAuthzId,
              user_name = UserName,
              user_id = UserId,
              requestor_authz_id = RequestorAuthzId}.
