%%--------------------------------------------------------------------
%% Copyright (c) 2024 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_cluster_link).

-behaviour(emqx_external_broker).

-export([
    register_external_broker/0,
    unregister_external_broker/0,
    maybe_add_route/1,
    maybe_delete_route/1,
    forward/2,
    should_route_to_external_dests/1
]).

%% emqx hooks
-export([
    put_hook/0,
    delete_hook/0,
    on_message_publish/1
]).

-include("emqx_cluster_link.hrl").
-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_hooks.hrl").
-include_lib("emqx/include/logger.hrl").

%%--------------------------------------------------------------------
%% emqx_external_broker API
%%--------------------------------------------------------------------

register_external_broker() ->
    emqx_external_broker:register_provider(?MODULE).

unregister_external_broker() ->
    emqx_external_broker:unregister_provider(?MODULE).

maybe_add_route(Topic) ->
    emqx_cluster_link_coordinator:route_op(<<"add">>, Topic).

maybe_delete_route(_Topic) ->
    %% Not implemented yet
    %% emqx_cluster_link_coordinator:route_op(<<"delete">>, Topic).
    ok.

forward(ExternalDest, Delivery) ->
    emqx_cluster_link_mqtt:forward(ExternalDest, Delivery).

%% Do not forward any external messages to other links.
%% Only forward locally originated messages to all the relevant links, i.e. no gossip message forwarding.
should_route_to_external_dests(#message{extra = #{link_origin := _}}) ->
    false;
should_route_to_external_dests(_Msg) ->
    true.

%%--------------------------------------------------------------------
%% EMQX Hooks
%%--------------------------------------------------------------------

on_message_publish(#message{topic = <<?ROUTE_TOPIC_PREFIX, ClusterName/binary>>, payload = Payload}) ->
    _ =
        case emqx_cluster_link_mqtt:decode_route_op(Payload) of
            {add, Topics} when is_list(Topics) ->
                add_routes(Topics, ClusterName);
            {add, Topic} ->
                emqx_router_syncer:push(add, Topic, ?DEST(ClusterName), #{});
            {delete, _} ->
                %% Not implemented yet
                ok;
            cleanup_routes ->
                cleanup_routes(ClusterName)
        end,
    {stop, []};
on_message_publish(#message{topic = <<?MSG_TOPIC_PREFIX, ClusterName/binary>>, payload = Payload}) ->
    case emqx_cluster_link_mqtt:decode_forwarded_msg(Payload) of
        #message{} = ForwardedMsg ->
            {stop, with_sender_name(ForwardedMsg, ClusterName)};
        _Err ->
            %% Just ignore it. It must be already logged by the decoder
            {stop, []}
    end;
on_message_publish(
    #message{topic = <<?CTRL_TOPIC_PREFIX, ClusterName/binary>>, payload = Payload} = Msg
) ->
    case emqx_cluster_link_mqtt:decode_ctrl_msg(Payload, ClusterName) of
        {init_link, InitRes} ->
            on_init(InitRes, ClusterName, Msg);
        {ack_link, Res} ->
            on_init_ack(Res, ClusterName, Msg);
        unlink ->
            %% Stop pushing messages to the cluster that requested unlink,
            %% It brings the link to a half-closed (unidirectional) state,
            %% as this cluster may still replicate routes and receive messages from ClusterName.
            emqx_cluster_link_mqtt:stop_msg_fwd_resource(ClusterName),
            cleanup_routes(ClusterName)
    end,
    {stop, []};
on_message_publish(_Msg) ->
    ok.

put_hook() ->
    emqx_hooks:put('message.publish', {?MODULE, on_message_publish, []}, ?HP_SYS_MSGS).

delete_hook() ->
    emqx_hooks:del('message.publish', {?MODULE, on_message_publish, []}).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

cleanup_routes(ClusterName) ->
    emqx_router:cleanup_routes(?DEST(ClusterName)).

lookup_link_conf(ClusterName) ->
    lists:search(
        fun(#{upstream := N}) -> N =:= ClusterName end,
        emqx:get_config([cluster, links], [])
    ).

on_init(Res, ClusterName, Msg) ->
    #{
        'Correlation-Data' := ReqId,
        'Response-Topic' := RespTopic
    } = emqx_message:get_header(properties, Msg),
    case lookup_link_conf(ClusterName) of
        {value, LinkConf} ->
            _ = emqx_cluster_link_mqtt:ensure_msg_fwd_resource(LinkConf),
            emqx_cluster_link_mqtt:ack_link(ClusterName, Res, RespTopic, ReqId);
        false ->
            ?SLOG(error, #{
                msg => "init_link_request_from_unknown_cluster",
                link_name => ClusterName
            }),
            %% Cannot ack/reply since we don't know how to reach the link cluster,
            %% The cluster that tried to initiatw this link is expected to eventually fail with timeout.
            ok
    end.

on_init_ack(Res, ClusterName, Msg) ->
    #{'Correlation-Data' := ReqId} = emqx_message:get_header(properties, Msg),
    emqx_cluster_link_coordinator:on_link_ack(ClusterName, ReqId, Res).

add_routes(Topics, ClusterName) ->
    lists:foreach(
        fun(T) -> emqx_router_syncer:push(add, T, ?DEST(ClusterName), #{}) end,
        Topics
    ).

%% let it crash if extra is not a map,
%% we don't expect the message to be forwarded from an older EMQX release,
%% that doesn't set extra = #{} by default.
with_sender_name(#message{extra = Extra} = Msg, ClusterName) when is_map(Extra) ->
    Msg#message{extra = Extra#{link_origin => ClusterName}}.
