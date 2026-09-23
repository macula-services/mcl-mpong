%%% @doc The challenger's paddle: it steers by the host's frames and reports
%%% what it measured of the mesh on every move.
%%%
%%% Frames go in through `state_frame/3' exactly as the coordinator hands them
%%% over after parsing; moves come out through the `emit' function, which here
%%% sends them to the test process.
-module(play_remote_paddle_tests).

-include_lib("eunit/include/eunit.hrl").

-define(GAME, <<"g-1">>).
-define(MOVE_WAIT_MS, 1000).

%% Each test gets its own paddle, stopped by the fixture even when the test
%% fails, so no paddle outlives its test to send moves into a later one.
paddle_test_() ->
    {foreach, local, fun start_paddle/0, fun stop/1,
     [with("no move is sent before the first frame gives it a ball", fun silent_until_a_ball/1),
      with("moves are numbered from 1 and are valid paddle facts", fun moves_are_numbered/1),
      with("frames seen and missed come from the host's frame_seq", fun frames_are_counted/1),
      with("an echoed move becomes a round-trip sample", fun echo_is_measured/1),
      with("the challenger reports its stations and how frames came", fun stations_and_via/1)]}.

with(Title, Test) -> fun(Pid) -> {Title, fun() -> Test(Pid) end} end.

%%--------------------------------------------------------------------

silent_until_a_ball(_Pid) ->
    receive {move, _} -> error(moved_without_a_ball)
    after 300 -> ok
    end.

moves_are_numbered(Pid) ->
    frame(Pid, 1, 0, 0, direct),
    #{move_seq := S1} = M1 = next_move(),
    #{move_seq := S2} = next_move(),
    ?assertEqual({1, 2}, {S1, S2}),
    ?assertMatch({ok, #{game_id := ?GAME, wall_index := 1}},
                 mcl_mpong_facts:parse(paddle_moved,
                                       macula_record_cbor:decode(macula_record_cbor:encode(M1)))).

frames_are_counted(Pid) ->
    [frame(Pid, Seq, 0, 0, direct) || Seq <- [1, 2, 4]],
    ?assertMatch(#{frames_seen := 3, frames_missed := 1}, move_after_frames()).

echo_is_measured(Pid) ->
    frame(Pid, 1, 0, 0, direct),
    #{move_seq := Seq} = next_move(),
    frame(Pid, 2, Seq, 0, direct),
    #{rtt_samples := N, rtt_ms_last := Last, rtt_ms_p50 := P50} = move_after_frames(),
    ?assertEqual(1, N),
    %% Local only: from the move leaving to its echo is well under a second.
    ?assert(Last >= 0 andalso Last < 1000),
    ?assertEqual(Last, P50).

stations_and_via(Pid) ->
    play_remote_paddle:stations(Pid, [<<"cc33">>]),
    frame(Pid, 1, 0, 0, plumtree),
    ?assertMatch(#{stations := [<<"cc33">>], frames_delivered_via := <<"plumtree">>},
                 move_after_frames()).

%%--------------------------------------------------------------------

start_paddle() ->
    flush(),
    Self = self(),
    {ok, Pid} = play_remote_paddle:start_link(
                  #{game_id => ?GAME, wall_index => 1,
                    emit => fun(Move) -> Self ! {move, Move}, ok end}),
    Pid.

stop(Pid) ->
    unlink(Pid),
    gen_server:stop(Pid),
    flush().

frame(Pid, FrameSeq, EchoSeq, HeldMs, Via) ->
    play_remote_paddle:state_frame(
      Pid, #{game_id => ?GAME, tick => FrameSeq * 5, frame_seq => FrameSeq,
             ball => #{y => 480, vx => 9},
             echo_move_seq => EchoSeq, echo_held_ms => HeldMs}, Via).

next_move() ->
    receive {move, Move} -> Move
    after ?MOVE_WAIT_MS -> error(no_move)
    end.

move_after_frames() ->
    timer:sleep(20),
    flush(),
    next_move().

flush() ->
    receive {move, _} -> flush()
    after 0 -> ok
    end.
