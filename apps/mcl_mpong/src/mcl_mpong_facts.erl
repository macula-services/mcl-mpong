%%% @doc The match's public contract: what two bots tell each other, and the
%%% spectator, over the mesh.
%%%
%%% Six integration facts, one topic each, owned by org `mcl-mpong', app
%%% `mpong', domain `match', for example
%%% `io.macula/mcl-mpong/mpong/match/state_broadcast_v2':
%%%
%%%   game_advertised_v2  a host's game is open, playing, ended or withdrawn
%%%   seat_requested_v2   a challenger asks for the open seat
%%%   seat_reserved_v2    the host gives it to one challenger
%%%   seat_denied_v2      the host refuses one, with the reason
%%%   paddle_moved_v2     the challenger's paddle, and its view of the mesh
%%%   state_broadcast_v2  the host's authoritative frame, and both views
%%%
%%% The `game_id' is in the payload, never in a topic.
%%%
%%% THE MATCH IS A MEASUREMENT. `paddle_moved' and `state_broadcast' carry what
%%% the two ends observed of each other through the mesh, so a spectator reads
%%% how the mesh carried the match off the same facts that drive it:
%%%
%%%   frames      the host numbers every frame (`frame_seq'); the challenger
%%%               reports how many it saw and how many it missed in the span
%%%   moves       the same, the other way: `move_seq', `moves_seen/missed'
%%%   round trip  the host echoes the last move it applied and how long it held
%%%               it; the challenger subtracts that from its own send-to-echo
%%%               time. Each side reads only its own clock, so no clock sync
%%%               is assumed.
%%%   stations    the node ids of the stations each end's pool is connected
%%%               to, and how the last fact arrived (`direct' or `plumtree')
%%%
%%% WHO SENT A FACT IS NOT IN THE PAYLOAD. macula 12 delivers every event with
%%% the publisher its link verified; the bots trust that, not a claim. Node ids
%%% that ARE in a payload name someone else (the host of a game, the challenger
%%% given a seat), in lowercase hex.
%%%
%%% Payload values are binaries, integers, lists and maps only. Flags are 1/0.
%%% Build functions take atom keys; `parse/2' reads what a subscriber receives,
%%% where macula's codec hands text back as `{text, Binary}'.
-module(mcl_mpong_facts).

-export([facts/0, topic/2, fact_of_topic/2, check_realm_name/2]).
-export([game_advertised/4, seat_requested/3, seat_reserved/4, seat_denied/4,
         paddle_moved/2, state_broadcast/2]).
-export([parse/2]).

-define(ORG, <<"mcl-mpong">>).
-define(APP, <<"mpong">>).
-define(DOMAIN, <<"match">>).
-define(VERSION, 2).
-define(MAX_PLAYERS, 2).
-define(ARENA, #{w => 1000, h => 1000}).

-type fact() :: game_advertised | seat_requested | seat_reserved | seat_denied
              | paddle_moved | state_broadcast.
-type game_status() :: open | playing | ended | withdrawn.

-export_type([fact/0, game_status/0]).

%%------------------------------------------------------------------------------
%% Topics
%%------------------------------------------------------------------------------

-spec facts() -> [fact()].
facts() ->
    [game_advertised, seat_requested, seat_reserved, seat_denied,
     paddle_moved, state_broadcast].

-spec topic(binary(), fact()) -> binary().
topic(RealmName, Fact) ->
    macula_topic:app_fact(RealmName, ?ORG, ?APP, ?DOMAIN,
                          atom_to_binary(Fact, utf8), ?VERSION).

-spec fact_of_topic(binary(), binary()) -> {ok, fact()} | error.
fact_of_topic(RealmName, Topic) ->
    first([F || F <- facts(), topic(RealmName, F) =:= Topic]).

first([F | _]) -> {ok, F};
first([])      -> error.

%% @doc The realm name the topics carry must be the realm the pool publishes
%% in. A topic naming one realm published in another reaches nobody, and looks
%% exactly like a quiet match.
-spec check_realm_name(binary(), binary()) -> ok.
check_realm_name(Name, Tag) ->
    matched(crypto:hash(sha256, Name) =:= Tag, Name, Tag).

matched(true, _Name, _Tag) -> ok;
matched(false, Name, Tag)  -> error({mcl_mpong_realm_name_mismatch, Name, Tag}).

%%------------------------------------------------------------------------------
%% Build
%%------------------------------------------------------------------------------

-spec game_advertised(binary(), game_status(), binary(), integer()) -> map().
game_advertised(GameId, Status, HostNodeId, AtMs) ->
    #{game_id => GameId, status => status_text(Status),
      host_node_id => HostNodeId, max_players => ?MAX_PLAYERS, at_ms => AtMs}.

-spec seat_requested(binary(), non_neg_integer(), integer()) -> map().
seat_requested(GameId, WallIndex, AtMs) ->
    #{game_id => GameId, wall_index => WallIndex, at_ms => AtMs}.

-spec seat_reserved(binary(), binary(), non_neg_integer(), integer()) -> map().
seat_reserved(GameId, ChallengerNodeId, WallIndex, AtMs) ->
    #{game_id => GameId, challenger_node_id => ChallengerNodeId,
      wall_index => WallIndex, at_ms => AtMs}.

-spec seat_denied(binary(), binary(), atom() | binary(), integer()) -> map().
seat_denied(GameId, ChallengerNodeId, Reason, AtMs) ->
    #{game_id => GameId, challenger_node_id => ChallengerNodeId,
      reason => text(Reason), at_ms => AtMs}.

%% @doc The challenger's paddle and what it has measured. `Report' carries
%% exactly the paddle keys; anything else is a contract change.
-spec paddle_moved(map(), integer()) -> map().
paddle_moved(Report, AtMs) ->
    (maps:with(paddle_keys(), Report))#{at_ms => AtMs}.

%% @doc The host's frame: the game as the engine holds it, the arena, and the
%% mesh block both ends measured.
-spec state_broadcast(map(), map()) -> map().
state_broadcast(GameState, Mesh) ->
    (maps:with(game_keys(), GameState))#{arena => ?ARENA,
                                         mesh => maps:with(mesh_keys(), Mesh)}.

paddle_keys() ->
    [game_id, wall_index, y, tick, move_seq, frames_seen, frames_missed,
     rtt_ms_last, rtt_ms_p50, rtt_samples, stations, frames_delivered_via].

game_keys() ->
    [game_id, ball, paddles, alive, points, games_won, serving, obstacles,
     paused, tick].

mesh_keys() ->
    [frame_seq, frames_sent, host_stations, moves_seen, moves_missed,
     moves_delivered_via, echo_move_seq, echo_held_ms, challenger].

status_text(open)      -> <<"open">>;
status_text(playing)   -> <<"playing">>;
status_text(ended)     -> <<"ended">>;
status_text(withdrawn) -> <<"withdrawn">>.

text(A) when is_atom(A)   -> atom_to_binary(A, utf8);
text(B) when is_binary(B) -> B.

%%------------------------------------------------------------------------------
%% Parse: what a subscriber receives
%%------------------------------------------------------------------------------

%% @doc Read a received payload as `Fact'. `{error, malformed}' for anything
%% that does not carry the contract's keys with the contract's types; a
%% consumer drops those rather than crash on another node's bad frame.
-spec parse(fact(), term()) -> {ok, map()} | {error, malformed}.
parse(Fact, Payload) when is_map(Payload) ->
    read(Fact, plain(Payload));
parse(_Fact, _Payload) ->
    {error, malformed}.

read(game_advertised, #{<<"game_id">> := G, <<"status">> := S,
                        <<"host_node_id">> := H, <<"max_players">> := M})
  when is_binary(G), is_binary(H), is_integer(M) ->
    advertised(status_of(S), #{game_id => G, host_node_id => H, max_players => M});
read(seat_requested, #{<<"game_id">> := G, <<"wall_index">> := W})
  when is_binary(G), is_integer(W) ->
    {ok, #{game_id => G, wall_index => W}};
read(seat_reserved, #{<<"game_id">> := G, <<"challenger_node_id">> := C,
                      <<"wall_index">> := W})
  when is_binary(G), is_binary(C), is_integer(W) ->
    {ok, #{game_id => G, challenger_node_id => C, wall_index => W}};
read(seat_denied, #{<<"game_id">> := G, <<"challenger_node_id">> := C,
                    <<"reason">> := R})
  when is_binary(G), is_binary(C), is_binary(R) ->
    {ok, #{game_id => G, challenger_node_id => C, reason => R}};
read(paddle_moved, #{<<"game_id">> := G} = P) when is_binary(G) ->
    paddle(P);
read(state_broadcast, #{<<"game_id">> := G, <<"tick">> := T,
                        <<"ball">> := #{<<"y">> := Y, <<"vx">> := Vx},
                        <<"mesh">> := #{<<"frame_seq">> := F,
                                        <<"echo_move_seq">> := E,
                                        <<"echo_held_ms">> := H}})
  when is_binary(G), is_integer(T), is_number(Y), is_integer(Vx),
       is_integer(F), is_integer(E), is_integer(H) ->
    {ok, #{game_id => G, tick => T, frame_seq => F,
           ball => #{y => round(Y), vx => Vx},
           echo_move_seq => E, echo_held_ms => H}};
read(_Fact, _Plain) ->
    {error, malformed}.

advertised({ok, Status}, Ad) -> {ok, Ad#{status => Status}};
advertised(error, _Ad)       -> {error, malformed}.

status_of(<<"open">>)      -> {ok, open};
status_of(<<"playing">>)   -> {ok, playing};
status_of(<<"ended">>)     -> {ok, ended};
status_of(<<"withdrawn">>) -> {ok, withdrawn};
status_of(_)               -> error.

%% Every paddle key must be present, integers where counted, and the station
%% list a list of binaries.
paddle(P) ->
    Read = [{K, maps:get(atom_to_binary(K, utf8), P, undefined)} || K <- paddle_keys()],
    paddle_typed(lists:all(fun paddle_typed/1, Read), Read).

paddle_typed(true, Read)  -> {ok, maps:from_list(Read)};
paddle_typed(false, _)    -> {error, malformed}.

paddle_typed({game_id, V})              -> is_binary(V);
paddle_typed({frames_delivered_via, V}) -> is_binary(V);
paddle_typed({stations, V})             -> is_list(V) andalso lists:all(fun is_binary/1, V);
paddle_typed({_Counted, V})             -> is_integer(V).

%% `{text, B}' back to `B', at any depth, so a received payload reads like a
%% built one with binary keys.
plain({text, B}) when is_binary(B) -> B;
plain(M) when is_map(M) -> maps:from_list([{plain(K), plain(V)} || {K, V} <- maps:to_list(M)]);
plain(L) when is_list(L) -> [plain(E) || E <- L];
plain(A) when is_atom(A), A =/= undefined -> atom_to_binary(A, utf8);
plain(V) -> V.
