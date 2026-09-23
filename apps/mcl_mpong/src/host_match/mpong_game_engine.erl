%%%-------------------------------------------------------------------
%%% @doc The host's game: the authoritative match loop, and the host's half of
%%% the mesh measurement.
%%%
%%% Integer grid 1000x1000, 25Hz ticks, ping-pong scoring (a game to 11, win
%%% by 2, best of 3). Wall 0 is this host's own bot; wall 1 is the challenger,
%%% whose paddle arrives over the mesh through `remote_paddle/3'.
%%%
%%% Every 5th tick the engine emits a frame, the `state_broadcast' payload,
%%% through the `emit' function it was started with. 5Hz is deliberate: a
%%% station's pubsub fanout dropped facts published every tick, while 5Hz is
%%% still smooth for a spectator.
%%%
%%% THE MATCH STATE LIVES IN THIS PROCESS AND NOWHERE ELSE. A match is
%%% throwaway: when it ends or the host restarts, it is gone, and the next one
%%% is found on the mesh. That is why this service keeps no event store.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_game_engine).
-behaviour(gen_server).

-export([start_link/1, remote_paddle/3, stations/2, pause/1, resume/1, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 40).            %% 25Hz
-define(FRAME_EVERY, 5).         %% a frame every 5th tick, 5Hz
-define(COUNTDOWN_TICKS, 50).    %% 2s pause between points
-define(GAME_POINT, 11).
-define(BEST_OF, 3).
-define(HOST_WALL, 0).
-define(REMOTE_WALL, 1).

-record(engine, {
    game_id      :: binary(),
    emit         :: fun((map()) -> ok),
    personality  :: mpong_ai:personality(),
    ball         :: mpong_ball:ball(),
    paddles      :: #{0 | 1 => integer()},
    obstacles    :: term(),
    points       :: #{0 | 1 => non_neg_integer()},
    games_won    :: #{0 | 1 => non_neg_integer()},
    serving      :: 0 | 1,
    total_pts    :: non_neg_integer(),
    tick = 0     :: non_neg_integer(),
    paused_until :: non_neg_integer(),
    suspended = false :: boolean(),
    %% The host's half of the measurement.
    frame_seq = 0 :: non_neg_integer(),
    moves        :: mesh_gauge:sequence(),
    moves_via = undefined :: atom(),
    echo = none  :: none | {integer(), integer()},   %% {move_seq, arrived_ms}
    challenger   :: map(),
    stations = [] :: [binary()]
}).

%%====================================================================
%% API
%%====================================================================

%% @doc `Config' is `#{game_id, emit}'. `emit' receives every frame.
-spec start_link(#{game_id := binary(), emit := fun((map()) -> ok)}) -> {ok, pid()}.
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

%% @doc The challenger's paddle arrived, parsed, and how it came.
-spec remote_paddle(pid(), map(), atom()) -> ok.
remote_paddle(Pid, Paddle, Via) ->
    gen_server:cast(Pid, {remote_paddle, Paddle, Via, now_ms()}).

%% @doc The stations this host's pool is connected to now.
-spec stations(pid(), [binary()]) -> ok.
stations(Pid, Stations) ->
    gen_server:cast(Pid, {stations, Stations}).

%% @doc Freeze the ball, paddles and score, indefinitely. Used when the
%% challenger's paddle goes silent on the mesh. Idempotent.
-spec pause(pid()) -> ok.
pause(Pid) -> gen_server:cast(Pid, suspend).

-spec resume(pid()) -> ok.
resume(Pid) -> gen_server:cast(Pid, resume).

-spec info(pid()) -> map().
info(Pid) -> gen_server:call(Pid, info).

%%====================================================================
%% gen_server
%%====================================================================

init(#{game_id := GameId, emit := Emit}) ->
    erlang:send_after(?TICK_MS, self(), tick),
    {ok, #engine{game_id = GameId, emit = Emit,
                 personality = mpong_ai:personality(),
                 ball = mpong_ball:new(),
                 paddles = #{?HOST_WALL => 500, ?REMOTE_WALL => 500},
                 obstacles = mpong_obstacles:new(),
                 points = #{0 => 0, 1 => 0},
                 games_won = #{0 => 0, 1 => 0},
                 serving = 0, total_pts = 0,
                 paused_until = ?COUNTDOWN_TICKS,
                 moves = mesh_gauge:sequence(),
                 challenger = no_report()}}.

handle_call(info, _From, #engine{game_id = GameId, ball = Ball, paddles = Paddles,
                                 suspended = Suspended, tick = Tick} = S) ->
    {reply, #{game_id => GameId, ball => mpong_ball:to_map(Ball), paddles => Paddles,
              suspended => Suspended, tick => Tick}, S}.

handle_cast({remote_paddle, #{y := Y, move_seq := Seq} = Paddle, Via, ArrivedMs},
            #engine{paddles = Paddles, moves = Moves} = S) ->
    {noreply, S#engine{paddles = Paddles#{?REMOTE_WALL => Y},
                       moves = mesh_gauge:observe(Seq, Moves),
                       moves_via = Via,
                       echo = latest(S#engine.echo, Seq, ArrivedMs),
                       challenger = challenger_report(Paddle)}};
handle_cast({stations, Stations}, S) ->
    {noreply, S#engine{stations = Stations}};
handle_cast(suspend, S) ->
    {noreply, S#engine{suspended = true}};
handle_cast(resume, S) ->
    {noreply, S#engine{suspended = false}}.

%% Suspended: freeze the ball, paddles and score, but keep ticking and
%% framing, so a spectator sees a paused game rather than a vanished one.
handle_info(tick, #engine{suspended = true} = S) ->
    {noreply, next_tick(framed(S))};
handle_info(tick, #engine{tick = Tick, paused_until = PausedUntil} = S0) ->
    S1 = moved(Tick >= PausedUntil, steer_host(S0)),
    over(check_match_over(S1), framed(S1)).

over(playing, S) -> {noreply, next_tick(S)};
over({won, _Wall}, S) -> {stop, normal, S}.

next_tick(#engine{tick = Tick} = S) ->
    erlang:send_after(?TICK_MS, self(), tick),
    S#engine{tick = Tick + 1}.

%%====================================================================
%% The measurement
%%====================================================================

%% The host echoes the LATEST move it applied. A move older than the one it
%% holds (reordered on the mesh) does not replace it.
latest({Held, _} = Echo, Seq, _ArrivedMs) when Seq =< Held -> Echo;
latest(_Echo, Seq, ArrivedMs) -> {Seq, ArrivedMs}.

challenger_report(Paddle) ->
    maps:with([frames_seen, frames_missed, rtt_ms_last, rtt_ms_p50, rtt_samples,
               stations, frames_delivered_via], Paddle).

no_report() ->
    #{frames_seen => 0, frames_missed => 0, rtt_ms_last => 0, rtt_ms_p50 => 0,
      rtt_samples => 0, stations => [], frames_delivered_via => <<"none">>}.

framed(#engine{tick = Tick} = S) when Tick rem ?FRAME_EVERY =/= 0 ->
    S;
framed(#engine{emit = Emit, frame_seq = Seq} = S0) ->
    S = S0#engine{frame_seq = Seq + 1},
    ok = Emit(mcl_mpong_facts:state_broadcast(game_state(S), mesh(S))),
    S.

mesh(#engine{frame_seq = Seq, moves = Moves, moves_via = Via, echo = Echo,
             challenger = Challenger, stations = Stations}) ->
    {EchoSeq, HeldMs} = echoed(Echo, now_ms()),
    #{frame_seq => Seq, frames_sent => Seq, host_stations => Stations,
      moves_seen => mesh_gauge:seen(Moves), moves_missed => mesh_gauge:missed(Moves),
      moves_delivered_via => mesh_gauge:via(Via),
      echo_move_seq => EchoSeq, echo_held_ms => HeldMs,
      challenger => Challenger}.

echoed(none, _Now) -> {0, 0};
echoed({Seq, ArrivedMs}, Now) -> {Seq, max(0, Now - ArrivedMs)}.

game_state(#engine{game_id = GameId, ball = Ball, paddles = Paddles, points = Points,
                   games_won = GamesWon, serving = Serving, obstacles = Obs,
                   tick = Tick, paused_until = PausedUntil, suspended = Suspended}) ->
    #{game_id => GameId, ball => mpong_ball:to_map(Ball), paddles => Paddles,
      alive => #{0 => 1, 1 => 1}, points => Points, games_won => GamesWon,
      serving => Serving, obstacles => mpong_obstacles:to_list(Obs),
      paused => flag(Suspended orelse Tick < PausedUntil), tick => Tick}.

flag(true) -> 1;
flag(false) -> 0.

%%====================================================================
%% The game
%%====================================================================

%% Only the host's own wall is steered here; the remote wall holds whatever
%% the challenger last sent.
steer_host(#engine{ball = Ball, paddles = Paddles, personality = P} = S) ->
    Y = mpong_ai:compute_paddle_position(mpong_ball:to_map(Ball),
                                         maps:get(?HOST_WALL, Paddles), ?HOST_WALL, P),
    S#engine{paddles = Paddles#{?HOST_WALL => Y}}.

moved(false, S) -> S;
moved(true, S) -> step(S).

step(#engine{ball = Ball0, paddles = Paddles, obstacles = Obs0, tick = Tick} = S) ->
    Ball1 = mpong_ball:tick(Ball0),
    Obs1 = mpong_obstacles:tick(Obs0, Tick),
    Ball2 = off_obstacle(mpong_obstacles:check_bounce(Ball1, Obs1), Ball1),
    on_paddle(mpong_collision:check_paddle(Ball2, Paddles, alive()),
              S#engine{ball = Ball2, obstacles = Obs1}).

off_obstacle({bounced, Ball}, _Ball) -> Ball;
off_obstacle({no_bounce, _}, Ball) -> Ball.

alive() -> #{0 => true, 1 => true}.

on_paddle({bounced, Ball}, S) ->
    S#engine{ball = Ball};
on_paddle(no_bounce, #engine{ball = Ball} = S) ->
    on_miss(mpong_collision:check_miss(Ball, alive()), S).

%% A miss scores for the OTHER wall.
on_miss({missed, Wall}, S) -> score_point(S, 1 - Wall);
on_miss(none, S) -> S.

score_point(#engine{points = Points0, total_pts = Total0, serving = Serving0} = S, Scorer) ->
    Pts = maps:get(Scorer, Points0) + 1,
    Points = Points0#{Scorer => Pts},
    OtherPts = maps:get(1 - Scorer, Points),
    Deuce = OtherPts >= ?GAME_POINT - 1 andalso Pts >= ?GAME_POINT - 1,
    Serving = next_server(Deuce, Total0 + 1, Serving0),
    point_scored(game_won(Pts, OtherPts), Scorer,
                 S#engine{points = Points, total_pts = Total0 + 1, serving = Serving}).

point_scored(true, Scorer, #engine{games_won = GW, serving = Serving, tick = Tick} = S) ->
    S#engine{games_won = GW#{Scorer => maps:get(Scorer, GW) + 1},
             points = #{0 => 0, 1 => 0}, total_pts = 0, serving = Scorer,
             ball = mpong_ball:serve(Serving),
             paused_until = Tick + ?COUNTDOWN_TICKS * 2};
point_scored(false, _Scorer, #engine{serving = Serving, tick = Tick} = S) ->
    S#engine{ball = mpong_ball:serve(Serving), paused_until = Tick + ?COUNTDOWN_TICKS}.

game_won(Pts, OtherPts) -> Pts >= ?GAME_POINT andalso Pts - OtherPts >= 2.

check_match_over(#engine{games_won = GW}) ->
    Needed = (?BEST_OF + 1) div 2,
    winner(maps:get(0, GW) >= Needed, maps:get(1, GW) >= Needed).

winner(true, _) -> {won, 0};
winner(_, true) -> {won, 1};
winner(_, _) -> playing.

%% Serve rotation: every point at deuce, otherwise every second point.
next_server(true, _TotalPts, Serving) -> 1 - Serving;
next_server(false, TotalPts, Serving) when TotalPts rem 2 =:= 0 -> 1 - Serving;
next_server(false, _TotalPts, Serving) -> Serving.

now_ms() -> erlang:monotonic_time(millisecond).
