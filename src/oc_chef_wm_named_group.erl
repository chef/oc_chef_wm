%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Stephen Delano <stephen@opscode.com>
%% Copyright 2013 Opscode, Inc. All Rights Reserved.

-module(oc_chef_wm_named_group).

-include_lib("eunit/include/eunit.hrl").
-include_lib("chef_wm/include/chef_wm.hrl").
-include("oc_chef_wm.hrl").

-mixin([{chef_wm_base, [content_types_accepted/2,
                        content_types_provided/2,
                        finish_request/2,
                        malformed_request/2,
                        ping/2]}]).

-mixin([{?BASE_RESOURCE, [forbidden/2,
                          is_authorized/2,
                          service_available/2]}]).

%% chef_wm behavior callbacks
-behaviour(chef_wm).
-export([auth_info/2,
         init/1,
         init_resource_state/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3]).

-export([allowed_methods/2,
         delete_resource/2,
         from_json/2,
         resource_exists/2,
         to_json/2]).

init(Config) ->
    chef_wm_base:init(?MODULE, Config).

init_resource_state(_Config) ->
    {ok, #group_state{}}.

request_type() ->
    "groups".

allowed_methods(Req, State) ->
    {['GET', 'PUT', 'DELETE'], Req, State}.

validate_request(Method, Req, State = #base_state{organization_guid = OrgId}) when Method == 'GET';
                                          Method == 'DELETE' ->
    {Req, State#base_state{superuser_bypasses_checks = true, resource_state = #group_state{oc_chef_group = #oc_chef_group{org_id = OrgId}}}};
validate_request('PUT', Req, #base_state{organization_guid = OrgId, resource_state = GroupState} = State) ->
    Body = wrq:req_body(Req),
    {ok, Group} = oc_chef_group:parse_binary_json(Body),
    {Req, State#base_state{
            superuser_bypasses_checks = true,
            resource_state = GroupState#group_state{
                               oc_chef_group = #oc_chef_group{org_id = OrgId},
                               group_data = Group}}}.

auth_info(Req, #base_state{chef_db_context = DbContext,
                           resource_state = GroupState,
                           organization_guid = OrgId} =State) ->
    GroupName = chef_wm_util:extract_from_path(group_name, Req),
    case chef_db:fetch(#oc_chef_group{org_id = OrgId, name = GroupName}, DbContext) of
        not_found ->
            Message = chef_wm_util:error_message_envelope(iolist_to_binary(["Cannot load group ",
                                                                            GroupName])),
            Req1 = chef_wm_util:set_json_body(Req, Message),
            {{halt, 404}, Req1, State#base_state{log_msg = group_not_found}};
        #oc_chef_group{authz_id = AuthzId} = Group ->
            GroupState1 = GroupState#group_state{oc_chef_group = Group},
            State1 = State#base_state{resource_state = GroupState1},
            {{group_id, AuthzId}, Req, State1}
    end.

resource_exists(Req, State) ->
    {true, Req, State}.

to_json(Req, #base_state{
                organization_name = OrgName,
                resource_state = #group_state{
                                             oc_chef_group = Group
                                            }} = State) ->   
    Ejson = oc_chef_group:assemble_group_ejson(Group, OrgName),
    
    Json = chef_json:encode(Ejson),
    error_logger:info_msg({group_to_json, wrq:method(Req)}),
    {Json, Req, State}.

from_json(Req, #base_state{resource_state = #group_state{
                                               oc_chef_group = Group,
                                               group_data = GroupData
                                              }
                          } = State) ->
    error_logger:info_msg({from_json, GroupData, Group}),
    chef_wm_base:update_from_json(Req, State, Group, GroupData).

delete_resource(Req, #base_state{
                        organization_name = OrgName,
                        chef_db_context = DbContext,
                                 requestor_id = RequestorId,
                                 resource_state = #group_state{
                                                     oc_chef_group = Group}
                                } = State) ->
    ok = oc_chef_wm_base:delete_object(DbContext, Group, RequestorId),
    Ejson = oc_chef_group:assemble_group_ejson(Group, OrgName),
    error_logger:info_msg({group_delete_resource, wrq:method(Req)}),
    {true, chef_wm_util:set_json_body(Req, Ejson), State}.

malformed_request_message(Any, _Req, _state) ->
    error({unexpected_malformed_request_message, Any}).