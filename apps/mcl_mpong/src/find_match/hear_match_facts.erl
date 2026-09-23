%%% @doc Hears one match topic on the mesh and hands each fact to `find_match'.
%%%
%%% One supervised `macula_subscriber' per topic, declared by the service's
%%% `subscriptions/0' and kept running by mcl_om. It parses nothing and decides
%%% nothing: the payload and the meta macula verified it under go to the
%%% coordinator as they arrived, and the coordinator judges them.
-module(hear_match_facts).

-behaviour(macula_subscriber).

-export([init/1, handle_event/4]).

-spec init(mcl_mpong_facts:fact()) -> {ok, mcl_mpong_facts:fact()}.
init(Fact) ->
    {ok, Fact}.

handle_event(_Topic, Payload, Meta, Fact) ->
    told(whereis(find_match), {match_fact, Fact, Payload, Meta}),
    {noreply, Fact}.

%% Nobody to tell yet (subscriptions start before the coordinator does), or
%% it is restarting: the fact is dropped, as a fact nobody subscribed to is.
told(undefined, _Msg) -> ok;
told(Pid, Msg) -> Pid ! Msg, ok.
