%% @doc The mcl_om service contract for mcl-mpong.
%%
%% Two bots play pong over the mesh, and the match reports how the mesh
%% carried it: round-trip latency, frames and moves lost, and the stations each
%% end is on. `find_match' pairs this bot with another; the facts both publish
%% are the contract in `mcl_mpong_facts'.
%%
%% NO EVENT STORE. A match is throwaway state held in the engine process; this
%% demo is a scoped waiver of the house rule that business processes are event
%% sourced (Raf, 2026-09-23).
%%
%% SIX CALLBACKS, ALL REQUIRED, plus `subscriptions/0'. mcl_om resolves them BY
%% NAME at startup, so the `-behaviour' attribute below turns a missing one into
%% a compile error.
-module(mcl_mpong_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0,
         subscriptions/0]).
-export([realm_name/0, health_of/1]).

%% Unpaired this long is the mesh failing to carry two bots to each other.
-define(UNPAIRED_LIMIT_MS, 900000).

info() ->
    #{name => <<"mcl-mpong">>,
      version => <<"0.1.0">>,
      description => <<"Two bots play pong over the mesh, and the match reports how the mesh carried it">>}.

%% The realm name the topics carry is checked against the realm the pool
%% publishes in before anything starts: a mismatch publishes where nobody
%% subscribed, and looks exactly like a bot with nobody to play.
start(_Opts) ->
    ok = realm_checked(mcl_om:realm()),
    mcl_mpong_sup:start_link().

realm_checked({ok, Tag}) -> mcl_mpong_facts:check_realm_name(realm_name(), Tag);
realm_checked(Other) -> error({mcl_mpong_realm_unset, realm_name(), Other}).

stop(_State) -> ok.

%% Health is the MATCH's health. A dark mesh on its own is not a failure here,
%% but a bot that stays unpaired far longer than a seek cycle is: that is the
%% mesh failing at the one thing this service exists to show.
health() ->
    health_of(coordinator_status()).

coordinator_status() ->
    try find_match:status(find_match)
    catch exit:_ -> unavailable
    end.

-spec health_of(map() | unavailable) -> mcl_om_service:health().
health_of(unavailable) ->
    {down, match_finder_unavailable};
health_of(#{unpaired_ms := Ms}) when Ms > ?UNPAIRED_LIMIT_MS ->
    {degraded, {unpaired_ms, Ms}};
health_of(#{}) ->
    ok.

%% Nothing callable. The bot's whole output is its published facts.
capabilities() -> [].

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
identity_spec() ->
    #{scope => <<"mcl-mpong">>,
      actions => [],
      resources => [],
      ttl_days => 30}.

%% One subscriber per match fact, each handing its facts to `find_match'.
subscriptions() ->
    Realm = realm_name(),
    [{mcl_mpong_facts:topic(Realm, F), hear_match_facts, F} || F <- mcl_mpong_facts:facts()].

%% @doc The realm NAME the topics carry (io.macula), where mcl_om's realm is
%% its sha256 tag.
-spec realm_name() -> binary().
realm_name() ->
    named(text(application:get_env(mcl_mpong, realm_name, undefined))).

named(undefined) -> error({mcl_mpong_realm_name_unset, realm_name});
named(Name) -> Name.

text(undefined) -> undefined;
text("") -> undefined;
text(<<>>) -> undefined;
text(S) when is_list(S) -> unicode:characters_to_binary(S);
text(B) when is_binary(B) -> B.
