%%% @doc What the match measures of the mesh, asserted without one.
%%%
%%% These are the numbers the spectator shows as mesh health, so each is
%%% checked against the case that would make it lie: a late or duplicate
%%% frame, an echo of a move nobody sent, a host that held a move before
%%% echoing it.
-module(mesh_gauge_tests).

-include_lib("eunit/include/eunit.hrl").

%%------------------------------------------------------------------------------
%% Sequence: frames or moves, seen and missed
%%------------------------------------------------------------------------------

nothing_seen_is_nothing_missed_test() ->
    G = mesh_gauge:sequence(),
    ?assertEqual({0, 0}, {mesh_gauge:seen(G), mesh_gauge:missed(G)}).

an_unbroken_run_misses_nothing_test() ->
    G = observe_all([5, 6, 7, 8], mesh_gauge:sequence()),
    ?assertEqual({4, 0}, {mesh_gauge:seen(G), mesh_gauge:missed(G)}).

a_gap_is_counted_as_missed_test() ->
    G = observe_all([1, 2, 5, 6], mesh_gauge:sequence()),
    ?assertEqual({4, 2}, {mesh_gauge:seen(G), mesh_gauge:missed(G)}).

%% Joining mid-game is not a loss: the span starts at the first seq seen.
the_span_starts_where_we_joined_test() ->
    G = observe_all([100, 101], mesh_gauge:sequence()),
    ?assertEqual(0, mesh_gauge:missed(G)).

%% A late frame fills its gap instead of being counted twice.
a_late_arrival_fills_its_gap_test() ->
    G = observe_all([1, 3, 2], mesh_gauge:sequence()),
    ?assertEqual({3, 0}, {mesh_gauge:seen(G), mesh_gauge:missed(G)}).

%% The pool dedups, but a gauge that double counted a replay would report a
%% healthier mesh than the one it measured.
a_repeat_is_not_seen_twice_test() ->
    G = observe_all([1, 2, 2, 3], mesh_gauge:sequence()),
    ?assertEqual({3, 0}, {mesh_gauge:seen(G), mesh_gauge:missed(G)}).

%%------------------------------------------------------------------------------
%% Round trip
%%------------------------------------------------------------------------------

no_echo_means_no_sample_test() ->
    G = mesh_gauge:sent(1, 1000, mesh_gauge:round_trip()),
    ?assertEqual({0, 0, 0}, rtt(G)).

%% Sent at 1000, echoed at 1200, held 20 by the host: 180 on the mesh.
the_hosts_hold_is_not_mesh_time_test() ->
    G0 = mesh_gauge:sent(1, 1000, mesh_gauge:round_trip()),
    G = mesh_gauge:echoed(1, 20, 1200, G0),
    ?assertEqual({180, 180, 1}, rtt(G)).

%% An echo of a move we never sent (or already measured) is not a sample.
an_unknown_echo_is_ignored_test() ->
    G0 = mesh_gauge:sent(1, 1000, mesh_gauge:round_trip()),
    G1 = mesh_gauge:echoed(9, 0, 1200, G0),
    ?assertEqual({0, 0, 0}, rtt(G1)),
    G2 = mesh_gauge:echoed(1, 0, 1100, G1),
    G3 = mesh_gauge:echoed(1, 0, 1900, G2),
    ?assertEqual({100, 100, 1}, rtt(G3)).

%% The host echoes the LATEST move it applied, so moves before it are settled
%% and must not be measured later against a much later echo.
an_echo_settles_every_earlier_move_test() ->
    G0 = sent_all([{1, 1000}, {2, 1040}, {3, 1080}], mesh_gauge:round_trip()),
    G1 = mesh_gauge:echoed(2, 0, 1200, G0),
    G2 = mesh_gauge:echoed(1, 0, 1300, G1),
    ?assertEqual({160, 160, 1}, rtt(G2)).

%% A hold longer than the round trip (clock step, bad host) never goes negative.
a_round_trip_is_never_negative_test() ->
    G0 = mesh_gauge:sent(1, 1000, mesh_gauge:round_trip()),
    ?assertEqual({0, 0, 1}, rtt(mesh_gauge:echoed(1, 500, 1100, G0))).

the_median_is_of_the_recent_window_test() ->
    G = lists:foldl(fun({Seq, Ms}, Acc) ->
                            mesh_gauge:echoed(Seq, 0, 1000 + Ms,
                                              mesh_gauge:sent(Seq, 1000, Acc))
                    end, mesh_gauge:round_trip(),
                    [{1, 100}, {2, 300}, {3, 200}]),
    ?assertEqual({200, 200, 3}, rtt(G)).

the_window_forgets_old_samples_test() ->
    G = lists:foldl(fun(Seq, Acc) ->
                            mesh_gauge:echoed(Seq, 0, 1000 + Seq,
                                              mesh_gauge:sent(Seq, 1000, Acc))
                    end, mesh_gauge:round_trip(), lists:seq(1, 100)),
    ?assertEqual(32, mesh_gauge:samples(G)),
    ?assertEqual(100, mesh_gauge:last(G)).

%% Moves the host never echoes must not accumulate for the life of the match.
unanswered_moves_are_bounded_test() ->
    G = sent_all([{S, S} || S <- lists:seq(1, 1000)], mesh_gauge:round_trip()),
    ?assert(mesh_gauge:pending(G) =< 64).

%%------------------------------------------------------------------------------
%% Stations
%%------------------------------------------------------------------------------

only_connected_stations_count_test() ->
    Links = [#{connected => true, node_id => <<16#AB, 16#CD>>},
             #{connected => false, node_id => <<16#01>>},
             #{connected => true, node_id => undefined},
             #{connected => true, node_id => <<16#00, 16#FF>>}],
    ?assertEqual([<<"00ff">>, <<"abcd">>], mesh_gauge:connected_stations(Links)).

delivery_channel_is_text_test() ->
    ?assertEqual([<<"direct">>, <<"plumtree">>, <<"none">>],
                 [mesh_gauge:via(V) || V <- [direct, plumtree, undefined]]).

%%------------------------------------------------------------------------------

observe_all(Seqs, G) -> lists:foldl(fun mesh_gauge:observe/2, G, Seqs).

sent_all(Sent, G) -> lists:foldl(fun({S, T}, Acc) -> mesh_gauge:sent(S, T, Acc) end, G, Sent).

rtt(G) -> {mesh_gauge:last(G), mesh_gauge:p50(G), mesh_gauge:samples(G)}.
