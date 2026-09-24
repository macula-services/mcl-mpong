%%% @doc Two bots find each other and play, over a bus that behaves like the
%%% mesh where it matters.
%%%
%%% The pure decisions (which role to take, when a silent paddle pauses or ends
%%% a game) are asserted directly. The whole handshake is then played by two
%%% real coordinators through `bus/0': every publication goes through macula's
%%% CBOR codec and reaches EVERY coordinator, the publisher included, with the
%%% publisher's node id in the delivery meta. That is the mesh's shape, and
%%% the one a coordinator can get wrong: it hears its own facts.
-module(find_match_tests).

-include_lib("eunit/include/eunit.hrl").

-define(A, <<16#AA:256>>).
-define(B, <<16#BB:256>>).
-define(C, <<16#CC:256>>).

%%------------------------------------------------------------------------------
%% Choosing a role
%%------------------------------------------------------------------------------

%% ⚠ A BOT THAT PLAYS MUST SAY SO IN ITS LOG. The first two bots on the fleet paired
%% and played while logging nothing after their node id, and "dead logs" sent the
%% diagnosis looking for a delivery fault that was not there (2026-09-24). Every
%% role change that matters to an operator is one info line.
line(From, To, Game, Peer) ->
    lists:flatten(io_lib:format("~ts", [find_match:lifecycle(From, To, Game, Peer)])).

hosting_is_logged_test() ->
    ?assertEqual("[mpong] hosting game g1, waiting for a challenger",
                 line(seeking, hosting, <<"g1">>, undefined)).

a_seat_request_is_logged_test() ->
    ?assertEqual("[mpong] seat requested in game g1 hosted by h1",
                 line(seeking, challenging, <<"g1">>, <<"h1">>)).

pairing_as_host_is_logged_test() ->
    ?assertEqual("[mpong] paired: hosting game g1 against c1",
                 line(hosting, playing_host, <<"g1">>, <<"c1">>)).

pairing_as_challenger_is_logged_test() ->
    ?assertEqual("[mpong] paired: seated in game g1 hosted by h1",
                 line(challenging, playing_remote, <<"g1">>, <<"h1">>)).

a_match_ending_is_logged_test() ->
    ?assertEqual("[mpong] match ended: game g1 against c1, seeking again",
                 line(playing_host, seeking, <<"g1">>, <<"c1">>)),
    ?assertEqual("[mpong] match ended: game g1 against h1, seeking again",
                 line(playing_remote, seeking, <<"g1">>, <<"h1">>)).

no_opponent_is_logged_test() ->
    ?assertEqual("[mpong] no opponent in game g1, seeking again",
                 line(hosting, seeking, <<"g1">>, undefined)),
    ?assertEqual("[mpong] no answer from game g1, seeking again",
                 line(challenging, seeking, <<"g1">>, <<"h1">>)).

the_first_seek_is_logged_and_nothing_else_is_silent_test() ->
    ?assertEqual("[mpong] seeking a game", line(starting, seeking, undefined, undefined)),
    ?assertEqual(silent, find_match:lifecycle(hosting, hosting, <<"g1">>, undefined)).

no_open_game_heard_means_host_test() ->
    ?assertEqual(host, find_match:decide_role([], hex(?A))).

an_open_game_heard_means_challenge_it_test() ->
    ?assertEqual({challenge, <<"g-2">>, hex(?B)},
                 find_match:decide_role([#{game_id => <<"g-2">>, host => hex(?B)}], hex(?A))).

our_own_game_is_not_an_opponent_test() ->
    ?assertEqual(host,
                 find_match:decide_role([#{game_id => <<"g-1">>, host => hex(?A)}], hex(?A))).

%% Two seekers who heard the same pair of games pick the same one, so they
%% collide on one host rather than splitting across two and both waiting.
the_lowest_game_id_is_challenged_test() ->
    Heard = [#{game_id => <<"g-9">>, host => hex(?B)},
             #{game_id => <<"g-3">>, host => hex(?C)}],
    ?assertEqual({challenge, <<"g-3">>, hex(?C)}, find_match:decide_role(Heard, hex(?A))).

%%------------------------------------------------------------------------------
%% A silent paddle
%%------------------------------------------------------------------------------

fresh_paddle_is_ok_test() ->
    ?assertEqual(ok, find_match:churn_action(1000, undefined, 2000, timings())).

stale_paddle_pauses_test() ->
    ?assertEqual(pause, find_match:churn_action(1000, undefined, 5000, timings())).

paused_within_grace_waits_test() ->
    ?assertEqual(ok, find_match:churn_action(1000, 5000, 9000, timings())).

paused_past_grace_ends_test() ->
    ?assertEqual(end_stale, find_match:churn_action(1000, 5000, 16000, timings())).

%%------------------------------------------------------------------------------
%% A silent host
%%------------------------------------------------------------------------------

%% A seated challenger reads the host's frames. A host that stops sending them
%% (restarted, crashed, cut off) ends the match for the challenger once the
%% silence passes `host_silence_ms'; before that it keeps its seat.
a_recent_frame_keeps_the_seat_test() ->
    ?assertEqual(ok, find_match:host_silence(1000, 5000, timings())).

a_host_silent_past_its_limit_ends_the_match_test() ->
    ?assertEqual(end_silent, find_match:host_silence(1000, 1000 + 5001, timings())).

%% The operator sees why the match ended: the game, the host and how long it
%% was silent (a fleet challenger sat 8 minutes in a dead game saying nothing,
%% 2026-09-24).
a_silent_host_is_logged_test() ->
    ?assertEqual("[mpong] host h1 silent for 5001 ms in game g1, ending the match",
                 lists:flatten(io_lib:format("~ts", [find_match:host_silent_line(<<"g1">>, <<"h1">>, 5001)]))).

%%------------------------------------------------------------------------------
%% Two bots, one match
%%------------------------------------------------------------------------------

two_bots_pair_and_measure_the_mesh_test_() ->
    {timeout, 30, fun two_bots_pair_and_measure_the_mesh/0}.

two_bots_pair_and_measure_the_mesh() ->
    Bus = bus(),
    {ok, A} = coordinator(?A, Bus),
    {ok, B} = coordinator(?B, Bus),
    Bus ! {coordinators, [{?A, A}, {?B, B}]},
    Bus ! {watch, self()},
    ok = wait_until(fun() -> roles(A, B) =:= lists:sort([playing_host, playing_remote]) end,
                    15000),
    %% The host's frames carry what the challenger measured and sent back:
    %% frames it saw, and a round trip of its own moves.
    Frame = wait_for_frame(fun(#{<<"mesh">> := #{<<"challenger">> := C}}) ->
                                   maps:get(<<"rtt_samples">>, C) > 0
                                       andalso maps:get(<<"frames_seen">>, C) > 0
                           end, 10000),
    #{<<"mesh">> := #{<<"moves_seen">> := MovesSeen, <<"echo_move_seq">> := Echo}} = Frame,
    ?assert(MovesSeen > 0),
    ?assert(Echo > 0),
    %% Playing, neither bot is unpaired.
    ?assertEqual([0, 0], [maps:get(unpaired_ms, find_match:status(P)) || P <- [A, B]]),
    [stop(P) || P <- [A, B]],
    exit(Bus, kill).

%% A lone bot cycles seeking -> hosting -> seeking. Its role clock restarts on
%% every cycle, so "how long without an opponent" has to be its own clock or a
%% bot alone for an hour reports a few seconds.
a_lone_bot_counts_its_unpaired_time_across_roles_test_() ->
    {timeout, 20, fun a_lone_bot_counts_its_unpaired_time_across_roles/0}.

a_lone_bot_counts_its_unpaired_time_across_roles() ->
    Bus = bus(),
    {ok, A} = coordinator(?A, (timings())#{host_wait_base_ms => 100,
                                           host_wait_jitter_ms => 100}, Bus),
    Bus ! {coordinators, [{?A, A}]},
    timer:sleep(2500),
    #{role_ms := RoleMs, unpaired_ms := UnpairedMs} = find_match:status(A),
    ?assert(UnpairedMs >= 2000),
    ?assert(RoleMs < UnpairedMs),
    stop(A),
    exit(Bus, kill).

%% A third bot arriving while the other two play is refused the seat, and a
%% refusal is a fact on the mesh, not a silence.
a_taken_seat_is_denied_test_() ->
    {timeout, 30, fun a_taken_seat_is_denied/0}.

a_taken_seat_is_denied() ->
    Bus = bus(),
    {ok, A} = coordinator(?A, Bus),
    {ok, B} = coordinator(?B, Bus),
    Bus ! {coordinators, [{?A, A}, {?B, B}]},
    Bus ! {watch, self()},
    ok = wait_until(fun() -> roles(A, B) =:= lists:sort([playing_host, playing_remote]) end,
                    15000),
    Host = host_of([{?A, A}, {?B, B}]),
    #{game_id := GameId} = find_match:status(Host),
    Bus ! {inject, ?C, seat_requested, mcl_mpong_facts:seat_requested(GameId, 1, 0)},
    wait_for_fact(seat_denied, fun(#{<<"challenger_node_id">> := Ch, <<"reason">> := R}) ->
                                       Ch =:= hex(?C) andalso R =:= <<"seat_taken">>
                               end, 5000),
    [stop(P) || P <- [A, B]],
    exit(Bus, kill).

%% A timer armed in one spell of a role must not act in a later spell of the
%% same role. A challenger is denied (its give-up timer still pending),
%% re-seeks and challenges again; the FIRST spell's give-up timer then fires
%% inside the second spell, which must not be cut short by it.
a_timer_from_an_earlier_spell_is_ignored_test_() ->
    {timeout, 20, fun a_timer_from_an_earlier_spell_is_ignored/0}.

a_timer_from_an_earlier_spell_is_ignored() ->
    Wait = 1500,
    Bus = bus(),
    {ok, A} = coordinator(?A, (timings())#{challenge_wait_ms => Wait}, Bus),
    Bus ! {coordinators, [{?A, A}]},
    Bus ! {watch, self()},
    Ad = fun() -> Bus ! {inject, ?B, game_advertised,
                         mcl_mpong_facts:game_advertised(<<"g-b">>, open, hex(?B), 0)} end,
    Advertiser = spawn(fun Loop() -> Ad(), timer:sleep(100), Loop() end),
    wait_for_fact(seat_requested, fun(_) -> true end, 5000),
    First = erlang:monotonic_time(millisecond),
    Bus ! {inject, ?B, seat_denied,
           mcl_mpong_facts:seat_denied(<<"g-b">>, hex(?A), seat_taken, 0)},
    wait_for_fact(seat_requested, fun(_) -> true end, 5000),
    exit(Advertiser, kill),
    %% Just past the first spell's timer, and still inside the second's.
    timer:sleep(max(0, First + Wait + 100 - erlang:monotonic_time(millisecond))),
    ?assertEqual(challenging, maps:get(role, find_match:status(A))),
    stop(A),
    exit(Bus, kill).

%% THE MIRROR CASES: either end of a match going silent ends it for the other,
%% which seeks again. On the fleet a host restarted mid-match and its seated
%% challenger never left the dead game, logging nothing and reporting healthy,
%% so the pair did not re-form until the challenger restarted too
%% (mcl-mpong#1, 2026-09-24).
a_challenger_whose_host_goes_silent_seeks_again_test_() ->
    {timeout, 30, fun a_challenger_whose_host_goes_silent_seeks_again/0}.

a_challenger_whose_host_goes_silent_seeks_again() ->
    Bus = bus(),
    Timings = (timings())#{host_silence_ms => 1500},
    {ok, A} = coordinator(?A, Timings, Bus),
    {ok, B} = coordinator(?B, Timings, Bus),
    Pairs = [{?A, A}, {?B, B}],
    Bus ! {coordinators, Pairs},
    ok = wait_until(fun() -> roles(A, B) =:= lists:sort([playing_host, playing_remote]) end,
                    15000),
    {HostId, Host} = paired_as(playing_host, Pairs),
    {_, Challenger} = paired_as(playing_remote, Pairs),
    %% The host goes dark: nothing it publishes reaches anyone any more.
    Bus ! {mute, HostId},
    ok = wait_until(fun() -> maps:get(peer_silent_ms, find_match:status(Challenger)) > 500 end,
                    3000),
    ok = wait_until(fun() -> maps:get(role, find_match:status(Challenger)) =/= playing_remote end,
                    4000),
    [stop(P) || P <- [Host, Challenger]],
    exit(Bus, kill).

a_host_whose_challenger_goes_silent_ends_the_game_test_() ->
    {timeout, 30, fun a_host_whose_challenger_goes_silent_ends_the_game/0}.

a_host_whose_challenger_goes_silent_ends_the_game() ->
    Bus = bus(),
    Timings = (timings())#{stale_ms => 500, grace_ms => 1000},
    {ok, A} = coordinator(?A, Timings, Bus),
    {ok, B} = coordinator(?B, Timings, Bus),
    Pairs = [{?A, A}, {?B, B}],
    Bus ! {coordinators, Pairs},
    Bus ! {watch, self()},
    ok = wait_until(fun() -> roles(A, B) =:= lists:sort([playing_host, playing_remote]) end,
                    15000),
    {HostId, Host} = paired_as(playing_host, Pairs),
    {ChallengerId, Challenger} = paired_as(playing_remote, Pairs),
    #{game_id := GameId} = find_match:status(Host),
    Bus ! {mute, ChallengerId},
    %% First the host pauses the game and says so in its frames, then it ends it.
    wait_for_frame(fun(#{<<"game_id">> := G, <<"paused">> := P}) -> G =:= GameId andalso P =:= 1;
                      (_) -> false
                   end, 5000),
    wait_for_fact(game_advertised, fun(#{<<"game_id">> := G, <<"status">> := S, <<"host_node_id">> := H}) ->
                                           G =:= GameId andalso S =:= <<"ended">> andalso H =:= hex(HostId)
                                   end, 5000),
    ?assertNotEqual(playing_host, maps:get(role, find_match:status(Host))),
    [stop(P) || P <- [Host, Challenger]],
    exit(Bus, kill).

paired_as(Role, Pairs) ->
    hd([{Id, P} || {Id, P} <- Pairs, maps:get(role, find_match:status(P)) =:= Role]).

%%------------------------------------------------------------------------------
%% The bus
%%------------------------------------------------------------------------------

%% Relays every publication to every coordinator through the real codec.
%% Eunit runs these tests in one process, so a watcher's mailbox still holds
%% the facts an earlier test's bus sent it; a new bus starts from an empty one.
bus() ->
    flush_seen(),
    spawn(fun() -> bus_loop([], [], []) end).

flush_seen() ->
    receive {seen, _, _} -> flush_seen()
    after 0 -> ok
    end.

%% A muted node's publications reach nobody: the node has gone dark.
bus_loop(Coordinators, Watchers, Muted) ->
    receive
        {coordinators, Cs} -> bus_loop(Cs, Watchers, Muted);
        {watch, Pid} -> bus_loop(Coordinators, [Pid | Watchers], Muted);
        {mute, Id} -> bus_loop(Coordinators, Watchers, [Id | Muted]);
        {inject, From, Fact, Payload} ->
            deliver(From, Fact, Payload, Coordinators, Watchers),
            bus_loop(Coordinators, Watchers, Muted);
        {publish, From, Fact, Payload} ->
            delivered(lists:member(From, Muted), From, Fact, Payload, Coordinators, Watchers),
            bus_loop(Coordinators, Watchers, Muted)
    end.

delivered(true, _From, _Fact, _Payload, _Coordinators, _Watchers) -> ok;
delivered(false, From, Fact, Payload, Coordinators, Watchers) ->
    deliver(From, Fact, Payload, Coordinators, Watchers).

deliver(From, Fact, Payload, Coordinators, Watchers) ->
    ok = macula_frame:check_payload(Payload),
    Received = macula_record_cbor:decode(macula_record_cbor:encode(Payload)),
    Meta = #{publisher => From, delivered_via => direct},
    [Pid ! {match_fact, Fact, Received, Meta} || {_Id, Pid} <- Coordinators],
    [W ! {seen, Fact, plain(Received)} || W <- Watchers],
    ok.

coordinator(NodeId, Bus) ->
    coordinator(NodeId, timings(), Bus).

coordinator(NodeId, Timings, Bus) ->
    Opts = Timings#{
        node_id => fun() -> {ok, NodeId} end,
        publish => fun(Fact, Payload) -> Bus ! {publish, NodeId, Fact, Payload}, ok end,
        stations => fun() -> [hex(NodeId)] end,
        start_engine => fun mpong_game_engine:start_link/1},
    find_match:start_link(Opts).

timings() ->
    #{seek_base_ms => 200, seek_jitter_ms => 400, reannounce_ms => 100,
      host_wait_base_ms => 1500, host_wait_jitter_ms => 1500,
      challenge_wait_ms => 1000, watchdog_ms => 200, stale_ms => 3000,
      grace_ms => 10000, host_silence_ms => 5000, stations_ms => 200}.

roles(A, B) ->
    lists:sort([maps:get(role, find_match:status(P)) || P <- [A, B]]).

host_of(Pairs) ->
    hd([P || {_Id, P} <- Pairs, maps:get(role, find_match:status(P)) =:= playing_host]).

stop(Pid) ->
    unlink(Pid),
    gen_server:stop(Pid).

wait_until(Check, Left) when Left =< 0 ->
    {timeout, Check()};
wait_until(Check, Left) ->
    wait_until(Check(), Check, Left).

wait_until(true, _Check, _Left) -> ok;
wait_until(false, Check, Left) ->
    timer:sleep(100),
    wait_until(Check, Left - 100).

wait_for_frame(Pred, Timeout) -> wait_for_fact(state_broadcast, Pred, Timeout).

wait_for_fact(Fact, Pred, Timeout) ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_for_fact(Fact, Pred, Deadline, erlang:monotonic_time(millisecond)).

wait_for_fact(_Fact, _Pred, Deadline, Now) when Now >= Deadline ->
    error(fact_not_seen);
wait_for_fact(Fact, Pred, Deadline, Now) ->
    receive
        {seen, Fact, Payload} -> matched(Pred(Payload), Payload, Fact, Pred, Deadline)
    after Deadline - Now -> error(fact_not_seen)
    end.

matched(true, Payload, _Fact, _Pred, _Deadline) -> Payload;
matched(false, _Payload, Fact, Pred, Deadline) ->
    wait_for_fact(Fact, Pred, Deadline, erlang:monotonic_time(millisecond)).

plain({text, B}) -> B;
plain(M) when is_map(M) -> maps:from_list([{plain(K), plain(V)} || {K, V} <- maps:to_list(M)]);
plain(L) when is_list(L) -> [plain(E) || E <- L];
plain(V) -> V.

hex(Id) -> binary:encode_hex(Id, lowercase).
