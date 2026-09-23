%%%-------------------------------------------------------------------
%%% @doc The challenger's paddle, and the challenger's half of the mesh
%%% measurement.
%%%
%%% Started by `find_match' once the host reserves our seat. The host is
%%% authoritative: this process keeps no game of its own. Frames come in
%%% (`state_frame/3', about 5Hz), paddle moves go out through `emit'.
%%%
%%% It steers at the engine's own 25Hz toward the last ball it saw, and sends a
%%% move every second step. Each move is numbered and reports what this end has
%%% measured: frames seen and missed, the round trip of its moves, the
%%% stations its pool is on, and how the last frame arrived.
%%% @end
%%%-------------------------------------------------------------------
-module(play_remote_paddle).
-behaviour(gen_server).

-export([start_link/1, state_frame/3, stations/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TICK_MS, 40).
-define(MOVE_EVERY, 2).

-record(st, {
    game_id      :: binary(),
    wall         :: non_neg_integer(),
    emit         :: fun((map()) -> ok),
    personality  :: mpong_ai:personality(),
    y = 500      :: integer(),
    ball         :: map() | undefined,
    tick = 0     :: non_neg_integer(),    %% the host's tick, from its last frame
    steps = 0    :: non_neg_integer(),
    move_seq = 0 :: non_neg_integer(),
    frames       :: mesh_gauge:sequence(),
    rtt          :: mesh_gauge:round_trip(),
    frames_via = undefined :: atom(),
    stations = [] :: [binary()]
}).

%%====================================================================
%% API
%%====================================================================

-spec start_link(#{game_id := binary(), wall_index := non_neg_integer(),
                   emit := fun((map()) -> ok)}) -> {ok, pid()}.
start_link(Config) ->
    gen_server:start_link(?MODULE, Config, []).

%% @doc A frame of our game arrived from the host, parsed, and how it came.
-spec state_frame(pid(), map(), atom()) -> ok.
state_frame(Pid, Frame, Via) ->
    gen_server:cast(Pid, {state_frame, Frame, Via, now_ms()}).

%% @doc The stations this challenger's pool is connected to now.
-spec stations(pid(), [binary()]) -> ok.
stations(Pid, Stations) ->
    gen_server:cast(Pid, {stations, Stations}).

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

%%====================================================================
%% gen_server
%%====================================================================

init(#{game_id := GameId, wall_index := Wall, emit := Emit}) ->
    erlang:send_after(?TICK_MS, self(), step),
    {ok, #st{game_id = GameId, wall = Wall, emit = Emit,
             personality = mpong_ai:personality(),
             frames = mesh_gauge:sequence(), rtt = mesh_gauge:round_trip()}}.

handle_call(_Request, _From, St) ->
    {reply, {error, unknown_call}, St}.

handle_cast({state_frame, #{game_id := GameId, tick := Tick, frame_seq := Seq, ball := Ball,
                            echo_move_seq := Echo, echo_held_ms := Held}, Via, NowMs},
            #st{game_id = GameId, frames = Frames, rtt = Rtt} = St) ->
    {noreply, St#st{ball = Ball, tick = Tick, frames_via = Via,
                    frames = mesh_gauge:observe(Seq, Frames),
                    rtt = mesh_gauge:echoed(Echo, Held, NowMs, Rtt)}};
handle_cast({state_frame, _OtherGame, _Via, _NowMs}, St) ->
    {noreply, St};
handle_cast({stations, Stations}, St) ->
    {noreply, St#st{stations = Stations}}.

handle_info(step, St) ->
    erlang:send_after(?TICK_MS, self(), step),
    {noreply, stepped(St)}.

%%====================================================================
%% Internal
%%====================================================================

%% Nothing to steer by until the first frame names a ball.
stepped(#st{ball = undefined} = St) ->
    St;
stepped(#st{ball = Ball, y = Y0, wall = Wall, personality = P, steps = Steps} = St) ->
    Y = mpong_ai:compute_paddle_position(Ball, Y0, Wall, P),
    moved((Steps + 1) rem ?MOVE_EVERY =:= 0, St#st{y = Y, steps = Steps + 1}).

moved(false, St) ->
    St;
moved(true, #st{emit = Emit, move_seq = Seq0, rtt = Rtt} = St0) ->
    Seq = Seq0 + 1,
    St = St0#st{move_seq = Seq, rtt = mesh_gauge:sent(Seq, now_ms(), Rtt)},
    ok = Emit(mcl_mpong_facts:paddle_moved(report(St), erlang:system_time(millisecond))),
    St.

report(#st{game_id = GameId, wall = Wall, y = Y, tick = Tick, move_seq = Seq,
           frames = Frames, rtt = Rtt, stations = Stations, frames_via = Via}) ->
    #{game_id => GameId, wall_index => Wall, y => Y, tick => Tick, move_seq => Seq,
      frames_seen => mesh_gauge:seen(Frames), frames_missed => mesh_gauge:missed(Frames),
      rtt_ms_last => mesh_gauge:last(Rtt), rtt_ms_p50 => mesh_gauge:p50(Rtt),
      rtt_samples => mesh_gauge:samples(Rtt),
      stations => Stations, frames_delivered_via => mesh_gauge:via(Via)}.

now_ms() -> erlang:monotonic_time(millisecond).
