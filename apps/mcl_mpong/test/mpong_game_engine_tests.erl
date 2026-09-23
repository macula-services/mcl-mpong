%%% @doc The host's engine: the game it plays and what it reports of the mesh.
%%%
%%% The engine ticks at 25Hz and emits a frame every 5th tick through the
%%% `emit' function it is given. Here that function sends the frame to the
%%% test process, so the frames are asserted exactly as they would be
%%% published, with no mesh.
-module(mpong_game_engine_tests).

-include_lib("eunit/include/eunit.hrl").

-define(COUNTDOWN_TICKS, 50).
-define(FRAME_WAIT_MS, 1000).

%% Each test gets its own engine, stopped by the fixture even when the test
%% fails. An engine left running keeps emitting frames into this process's
%% mailbox, which eunit shares across tests, and a later test then reads a
%% stranger's frame as its own. `local' keeps setup, test and teardown in one
%% process, the one the engine's frames are sent to.
engine_test_() ->
    {foreach, local, fun start_engine/0, fun stop/1,
     [with("a remote wall holds the position the challenger sent", fun remote_wall_holds_position/1),
      with({timeout, 20}, "suspend freezes the ball; resume restarts it", fun suspend_resume/1),
      with("frames are numbered from 1 and counted as sent", fun frames_are_numbered/1),
      with("every frame is publishable, flags as 1/0", fun frames_are_publishable/1),
      with("moves seen and missed come from the challenger's move_seq", fun moves_are_counted/1),
      with("the latest move is echoed with how long the host held it", fun latest_move_is_echoed/1),
      with("the challenger's own report rides along in the frame", fun challenger_report_rides_along/1),
      with("the host's stations are in the frame", fun host_stations_are_reported/1),
      with("before any move the frame says so, not a made-up number", fun no_move_yet/1)]}.

with(Title, Test) -> fun(Pid) -> {Title, fun() -> Test(Pid) end} end.

with({timeout, S}, Title, Test) -> fun(Pid) -> {Title, {timeout, S, fun() -> Test(Pid) end}} end.

%%--------------------------------------------------------------------

remote_wall_holds_position(Pid) ->
    mpong_game_engine:remote_paddle(Pid, move(1, 250), direct),
    wait_ticks(Pid, 5),
    #{paddles := Paddles} = mpong_game_engine:info(Pid),
    ?assertEqual(250, maps:get(1, Paddles)).

%% Measured in the engine's own ticks, not wall time: a loaded machine ticks
%% slower, and a sleep that is "past the countdown" on one box is not on another.
suspend_resume(Pid) ->
    mpong_game_engine:pause(Pid),
    Ball0 = ball(Pid),
    wait_ticks(Pid, ?COUNTDOWN_TICKS + 10),
    Ball1 = ball(Pid),
    ?assertEqual(Ball0, Ball1),
    mpong_game_engine:resume(Pid),
    wait_ticks(Pid, 5),
    ?assertNotEqual(Ball1, ball(Pid)).

frames_are_numbered(_Pid) ->
    #{mesh := #{frame_seq := F1, frames_sent := S1}} = next_frame(),
    #{mesh := #{frame_seq := F2, frames_sent := S2}} = next_frame(),
    ?assertEqual({1, 1, 2, 2}, {F1, S1, F2, S2}).

frames_are_publishable(_Pid) ->
    Frame = next_frame(),
    ?assertEqual(ok, macula_frame:check_payload(Frame)),
    #{paused := Paused, alive := Alive} = Frame,
    ?assert(lists:member(Paused, [0, 1])),
    ?assertEqual(#{0 => 1, 1 => 1}, Alive),
    ?assertEqual(Frame, mcl_mpong_facts:state_broadcast(Frame, maps:get(mesh, Frame))).

moves_are_counted(Pid) ->
    [mpong_game_engine:remote_paddle(Pid, move(Seq, 400), plumtree) || Seq <- [1, 2, 4]],
    #{mesh := Mesh} = frame_after_moves(),
    ?assertMatch(#{moves_seen := 3, moves_missed := 1,
                   moves_delivered_via := <<"plumtree">>}, Mesh).

latest_move_is_echoed(Pid) ->
    mpong_game_engine:remote_paddle(Pid, move(3, 400), direct),
    mpong_game_engine:remote_paddle(Pid, move(7, 410), direct),
    #{mesh := #{echo_move_seq := Echo, echo_held_ms := Held}} = frame_after_moves(),
    ?assertEqual(7, Echo),
    %% Held from arrival to this frame: at most one frame period plus slack.
    ?assert(Held >= 0 andalso Held =< 400).

challenger_report_rides_along(Pid) ->
    mpong_game_engine:remote_paddle(Pid, move(1, 400), direct),
    #{mesh := #{challenger := C}} = frame_after_moves(),
    ?assertEqual(#{frames_seen => 11, frames_missed => 1, rtt_ms_last => 90,
                   rtt_ms_p50 => 85, rtt_samples => 4, stations => [<<"cc33">>],
                   frames_delivered_via => <<"direct">>}, C).

host_stations_are_reported(Pid) ->
    mpong_game_engine:stations(Pid, [<<"ee55">>, <<"ff66">>]),
    timer:sleep(50),
    flush_frames(),
    #{mesh := #{host_stations := Stations}} = next_frame(),
    ?assertEqual([<<"ee55">>, <<"ff66">>], Stations).

no_move_yet(_Pid) ->
    #{mesh := Mesh} = next_frame(),
    ?assertMatch(#{echo_move_seq := 0, echo_held_ms := 0, moves_seen := 0,
                   moves_missed := 0, moves_delivered_via := <<"none">>,
                   challenger := #{rtt_samples := 0, frames_seen := 0,
                                   frames_delivered_via := <<"none">>}}, Mesh).

%%--------------------------------------------------------------------

start_engine() ->
    flush_frames(),
    Self = self(),
    GameId = list_to_binary("test-" ++ integer_to_list(erlang:unique_integer([positive]))),
    {ok, Pid} = mpong_game_engine:start_link(
                  #{game_id => GameId, emit => fun(Frame) -> Self ! {frame, Frame}, ok end}),
    Pid.

stop(Pid) ->
    unlink(Pid),
    gen_server:stop(Pid),
    flush_frames().

wait_ticks(Pid, N) ->
    #{tick := Start} = mpong_game_engine:info(Pid),
    wait_tick(Pid, Start + N, 400).

wait_tick(_Pid, _Target, 0) -> error(engine_not_ticking);
wait_tick(Pid, Target, Left) ->
    ticked(maps:get(tick, mpong_game_engine:info(Pid)) >= Target, Pid, Target, Left).

ticked(true, _Pid, _Target, _Left) -> ok;
ticked(false, Pid, Target, Left) -> timer:sleep(20), wait_tick(Pid, Target, Left - 1).

move(Seq, Y) ->
    #{game_id => <<"ignored-by-the-engine">>, wall_index => 1, y => Y, tick => 0,
      move_seq => Seq, frames_seen => 11, frames_missed => 1,
      rtt_ms_last => 90, rtt_ms_p50 => 85, rtt_samples => 4,
      stations => [<<"cc33">>], frames_delivered_via => <<"direct">>}.

ball(Pid) -> maps:get(ball, mpong_game_engine:info(Pid)).

next_frame() ->
    receive {frame, Frame} -> Frame
    after ?FRAME_WAIT_MS -> error(no_frame)
    end.

%% Casts are ordered before the next tick, so the first frame emitted after
%% flushing already reflects every move sent above.
frame_after_moves() ->
    timer:sleep(20),
    flush_frames(),
    next_frame().

flush_frames() ->
    receive {frame, _} -> flush_frames()
    after 0 -> ok
    end.
