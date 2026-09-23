%%% @doc The match's public contract: six topics and six payloads.
%%%
%%% macula-portal's mpong spectator is repointed at exactly this, so every
%%% topic segment and every key is pinned here. A change that breaks one of
%%% these tests is a change to the contract, and it gets a new `_vN', not an
%%% edit.
%%%
%%% The payloads are asserted twice: as built, and as a subscriber gets them
%%% back after macula's own CBOR codec (text keys arrive as `{text, Key}').
%%% Parsing the second form is what a consumer has to do, so the round trip is
%%% what proves a fact is readable, not the map this module happens to build.
-module(mcl_mpong_facts_tests).

-include_lib("eunit/include/eunit.hrl").

-define(REALM_NAME, <<"io.macula">>).
-define(HOST, <<"aa11">>).
-define(CHALLENGER, <<"bb22">>).

%%------------------------------------------------------------------------------
%% Topics
%%------------------------------------------------------------------------------

topics_are_the_published_contract_test() ->
    ?assertEqual(
       [<<"io.macula/mcl-mpong/mpong/match/game_advertised_v2">>,
        <<"io.macula/mcl-mpong/mpong/match/seat_requested_v2">>,
        <<"io.macula/mcl-mpong/mpong/match/seat_reserved_v2">>,
        <<"io.macula/mcl-mpong/mpong/match/seat_denied_v2">>,
        <<"io.macula/mcl-mpong/mpong/match/paddle_moved_v2">>,
        <<"io.macula/mcl-mpong/mpong/match/state_broadcast_v2">>],
       [mcl_mpong_facts:topic(?REALM_NAME, F) || F <- mcl_mpong_facts:facts()]).

%% macula's own parser is the judge of a canonical topic, not this module.
every_topic_is_a_canonical_app_fact_test() ->
    [begin
         {ok, Parsed} = macula_topic:parse(mcl_mpong_facts:topic(?REALM_NAME, F)),
         ?assertMatch(#{tier := app, org := <<"mcl-mpong">>, app := <<"mpong">>,
                        domain := <<"match">>, version := 2}, Parsed)
     end || F <- mcl_mpong_facts:facts()].

%% Raf, 2026-09-23: no "hecate" in any live topic.
no_topic_names_the_retired_service_test() ->
    [?assertEqual(nomatch, binary:match(mcl_mpong_facts:topic(?REALM_NAME, F),
                                        <<"hecate">>))
     || F <- mcl_mpong_facts:facts()].

a_topic_maps_back_to_its_fact_test() ->
    [?assertEqual({ok, F},
                  mcl_mpong_facts:fact_of_topic(?REALM_NAME,
                                                mcl_mpong_facts:topic(?REALM_NAME, F)))
     || F <- mcl_mpong_facts:facts()],
    ?assertEqual(error, mcl_mpong_facts:fact_of_topic(?REALM_NAME, <<"io.macula/x">>)).

%%------------------------------------------------------------------------------
%% The realm name the topics carry must be the realm the pool publishes in
%%------------------------------------------------------------------------------

realm_name_hashing_to_the_realm_tag_is_accepted_test() ->
    ?assertEqual(ok, mcl_mpong_facts:check_realm_name(
                       ?REALM_NAME, crypto:hash(sha256, ?REALM_NAME))).

realm_name_for_another_realm_is_refused_test() ->
    Tag = crypto:hash(sha256, <<"org.example">>),
    ?assertError({mcl_mpong_realm_name_mismatch, ?REALM_NAME, Tag},
                 mcl_mpong_facts:check_realm_name(?REALM_NAME, Tag)).

%%------------------------------------------------------------------------------
%% Payloads, as built
%%------------------------------------------------------------------------------

game_advertised_names_the_game_and_its_host_test() ->
    ?assertEqual(#{game_id => <<"g-1">>, status => <<"open">>,
                   host_node_id => ?HOST, max_players => 2, at_ms => 1000},
                 mcl_mpong_facts:game_advertised(<<"g-1">>, open, ?HOST, 1000)).

every_game_status_is_a_business_word_test() ->
    ?assertEqual([<<"open">>, <<"playing">>, <<"ended">>, <<"withdrawn">>],
                 [maps:get(status, mcl_mpong_facts:game_advertised(<<"g">>, S, ?HOST, 1))
                  || S <- [open, playing, ended, withdrawn]]).

seat_requested_carries_no_sender_test() ->
    %% Who asks is the verified publisher macula delivers with the event,
    %% not something the payload may claim.
    ?assertEqual(#{game_id => <<"g-1">>, wall_index => 1, at_ms => 1000},
                 mcl_mpong_facts:seat_requested(<<"g-1">>, 1, 1000)).

seat_reserved_names_who_got_the_seat_test() ->
    ?assertEqual(#{game_id => <<"g-1">>, challenger_node_id => ?CHALLENGER,
                   wall_index => 1, at_ms => 1000},
                 mcl_mpong_facts:seat_reserved(<<"g-1">>, ?CHALLENGER, 1, 1000)).

seat_denied_says_why_test() ->
    ?assertEqual(#{game_id => <<"g-1">>, challenger_node_id => ?CHALLENGER,
                   reason => <<"seat_taken">>, at_ms => 1000},
                 mcl_mpong_facts:seat_denied(<<"g-1">>, ?CHALLENGER, seat_taken, 1000)).

paddle_moved_carries_the_challengers_view_of_the_mesh_test() ->
    ?assertEqual(paddle_payload(), mcl_mpong_facts:paddle_moved(paddle_report(), 1000)).

state_broadcast_carries_the_game_and_the_mesh_test() ->
    ?assertEqual(state_payload(), mcl_mpong_facts:state_broadcast(game_state(), mesh_report())).

%% No booleans on the wire: flags travel as 1/0 (the mesh's house rule).
no_payload_carries_a_boolean_test() ->
    [?assertEqual([], booleans_in(P)) || P <- all_payloads()].

every_payload_is_admissible_to_macula_test() ->
    [?assertEqual(ok, macula_frame:check_payload(P)) || P <- all_payloads()].

%%------------------------------------------------------------------------------
%% Payloads, as a subscriber receives them
%%------------------------------------------------------------------------------

game_advertised_reads_back_test() ->
    ?assertEqual({ok, #{game_id => <<"g-1">>, status => open,
                        host_node_id => ?HOST, max_players => 2}},
                 received(game_advertised,
                          mcl_mpong_facts:game_advertised(<<"g-1">>, open, ?HOST, 1000))).

seat_requested_reads_back_test() ->
    ?assertEqual({ok, #{game_id => <<"g-1">>, wall_index => 1}},
                 received(seat_requested, mcl_mpong_facts:seat_requested(<<"g-1">>, 1, 1000))).

seat_reserved_reads_back_test() ->
    ?assertEqual({ok, #{game_id => <<"g-1">>, challenger_node_id => ?CHALLENGER,
                        wall_index => 1}},
                 received(seat_reserved,
                          mcl_mpong_facts:seat_reserved(<<"g-1">>, ?CHALLENGER, 1, 1000))).

seat_denied_reads_back_test() ->
    ?assertEqual({ok, #{game_id => <<"g-1">>, challenger_node_id => ?CHALLENGER,
                        reason => <<"seat_taken">>}},
                 received(seat_denied,
                          mcl_mpong_facts:seat_denied(<<"g-1">>, ?CHALLENGER, seat_taken, 1000))).

paddle_moved_reads_back_test() ->
    ?assertEqual({ok, maps:remove(at_ms, paddle_payload())},
                 received(paddle_moved, mcl_mpong_facts:paddle_moved(paddle_report(), 1000))).

%% The challenger reads back only what it steers and measures by.
state_broadcast_reads_back_test() ->
    ?assertEqual({ok, #{game_id => <<"g-1">>, tick => 40, frame_seq => 8,
                        ball => #{y => 480, vx => -9},
                        echo_move_seq => 17, echo_held_ms => 12}},
                 received(state_broadcast,
                          mcl_mpong_facts:state_broadcast(game_state(), mesh_report()))).

malformed_payload_is_refused_not_crashed_on_test() ->
    [?assertEqual({error, malformed}, mcl_mpong_facts:parse(F, #{<<"game_id">> => 7}))
     || F <- mcl_mpong_facts:facts()],
    ?assertEqual({error, malformed}, mcl_mpong_facts:parse(paddle_moved, not_a_map)).

unknown_status_is_malformed_test() ->
    Bad = (mcl_mpong_facts:game_advertised(<<"g">>, open, ?HOST, 1))#{status => <<"exploded">>},
    ?assertEqual({error, malformed}, received(game_advertised, Bad)).

%%------------------------------------------------------------------------------
%% Fixtures
%%------------------------------------------------------------------------------

paddle_report() ->
    #{game_id => <<"g-1">>, wall_index => 1, y => 512, tick => 40, move_seq => 17,
      frames_seen => 30, frames_missed => 2,
      rtt_ms_last => 180, rtt_ms_p50 => 175, rtt_samples => 12,
      stations => [<<"cc33">>, <<"dd44">>], frames_delivered_via => <<"direct">>}.

paddle_payload() ->
    (paddle_report())#{at_ms => 1000}.

game_state() ->
    #{game_id => <<"g-1">>,
      ball => #{x => 500, y => 480, vx => -9, vy => 3, r => 15, spin => 0},
      paddles => #{0 => 500, 1 => 512},
      alive => #{0 => 1, 1 => 1},
      points => #{0 => 3, 1 => 2},
      games_won => #{0 => 0, 1 => 1},
      serving => 1,
      obstacles => [#{x => 400, y => 300, hw => 30, hh => 25, ttl => 90}],
      paused => 0,
      tick => 40}.

mesh_report() ->
    #{frame_seq => 8, frames_sent => 8, host_stations => [<<"ee55">>],
      moves_seen => 15, moves_missed => 1, moves_delivered_via => <<"plumtree">>,
      echo_move_seq => 17, echo_held_ms => 12,
      challenger => #{frames_seen => 7, frames_missed => 0,
                      rtt_ms_last => 180, rtt_ms_p50 => 175, rtt_samples => 12,
                      stations => [<<"cc33">>], frames_delivered_via => <<"direct">>}}.

state_payload() ->
    (game_state())#{arena => #{w => 1000, h => 1000}, mesh => mesh_report()}.

all_payloads() ->
    [mcl_mpong_facts:game_advertised(<<"g">>, open, ?HOST, 1),
     mcl_mpong_facts:seat_requested(<<"g">>, 1, 1),
     mcl_mpong_facts:seat_reserved(<<"g">>, ?CHALLENGER, 1, 1),
     mcl_mpong_facts:seat_denied(<<"g">>, ?CHALLENGER, seat_taken, 1),
     mcl_mpong_facts:paddle_moved(paddle_report(), 1),
     mcl_mpong_facts:state_broadcast(game_state(), mesh_report())].

%% Through macula's codec and back, as a subscriber's payload arrives.
received(Fact, Payload) ->
    Wire = macula_record_cbor:encode(Payload),
    mcl_mpong_facts:parse(Fact, macula_record_cbor:decode(Wire)).

booleans_in(true) -> [true];
booleans_in(false) -> [false];
booleans_in(M) when is_map(M) ->
    lists:append([booleans_in(K) ++ booleans_in(V) || {K, V} <- maps:to_list(M)]);
booleans_in(L) when is_list(L) -> lists:append([booleans_in(E) || E <- L]);
booleans_in(_) -> [].
