%%%-------------------------------------------------------------------
%%% @doc Two bots finding each other on the mesh, and running the match.
%%%
%%% One per bot. It owns the bot's role and its current match end to end, and
%%% it is race-free by construction: a jittered seek window makes each bot a
%%% host XOR a challenger, never both at once.
%%%
%%%   SEEKING ──hears an open game──▶ CHALLENGING ──seat_reserved──▶ PLAYING_REMOTE
%%%       │                              └─seat_denied / no answer─▶ SEEKING
%%%       └──window expires, none heard──▶ HOSTING ──seat requested──▶ PLAYING_HOST
%%%                                           └─no challenger in time─▶ SEEKING
%%%
%%% EVERY FACT IS ATTRIBUTED BY ITS VERIFIED PUBLISHER, never by the payload.
%%% A seat goes to whoever macula says asked for it, a paddle move counts only
%%% from the challenger holding the seat, and a frame only from the host of our
%%% game. The mesh also hands a bot back its own facts, so a fact from our own
%%% node id is ignored.
%%%
%%% Seams are options so a test can run two of these through a fake mesh:
%%% `node_id', `publish', `stations', `start_engine', and the timings.
%%% @end
%%%-------------------------------------------------------------------
-module(find_match).
-behaviour(gen_server).

-export([start_link/1, status/1, decide_role/2, churn_action/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(REMOTE_WALL, 1).
-define(DEFAULTS, #{
    seek_base_ms => 3000, seek_jitter_ms => 3000,
    %% Reannounce MUST be shorter than the shortest seek window, so a seeker is
    %% guaranteed to hear a host at least once.
    reannounce_ms => 2000,
    %% A host with no challenger re-seeks (breaks the two-hosts deadlock); a
    %% challenger whose request goes unanswered re-seeks.
    host_wait_base_ms => 6000, host_wait_jitter_ms => 6000,
    challenge_wait_ms => 5000,
    %% The host pauses when the remote paddle goes silent, and ends the game if
    %% it stays silent past the grace window.
    watchdog_ms => 1000, stale_ms => 3000, grace_ms => 10000,
    %% How often each end reads which stations its pool is on.
    stations_ms => 5000}).

-record(st, {
    opts        :: map(),
    me          :: binary() | undefined,     %% our node id, lowercase hex
    role = starting :: starting | seeking | hosting | challenging
                     | playing_host | playing_remote,
    role_since  :: integer(),
    %% Bumped on every role change. A role's timers carry the epoch they were
    %% armed in and act only in it, so a timer left over from an earlier spell
    %% of the same role cannot cut a later spell short.
    epoch = 0   :: non_neg_integer(),
    %% When this bot last stopped playing (or started); undefined while it
    %% plays. The role clock restarts every seek cycle, so a lone bot needs
    %% this one to say how long it has had nobody to play.
    unpaired_since :: integer() | undefined,
    game_id     :: binary() | undefined,
    peer        :: binary() | undefined,     %% the other bot in our game
    engine      :: {pid(), reference()} | undefined,
    paddle      :: pid() | undefined,
    last_paddle_ms :: integer() | undefined,
    paused_since   :: integer() | undefined,
    heard = []  :: [#{game_id := binary(), host := binary()}],
    stations = [] :: [binary()]
}).

%%====================================================================
%% API
%%====================================================================

%% @doc `Opts' overrides the seams and timings; `name' registers it locally.
-spec start_link(map()) -> {ok, pid()}.
start_link(#{name := Name} = Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, Opts, []);
start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% @doc The bot's role, its game, how long it has held the role, and how long
%% it has been without an opponent (0 while it plays).
-spec status(pid() | atom()) -> #{role := atom(), game_id := binary() | undefined,
                                  role_ms := non_neg_integer(),
                                  unpaired_ms := non_neg_integer()}.
status(Server) ->
    gen_server:call(Server, status).

%% @doc Given the open games heard during the seek window and our own node id:
%% HOST if none is joinable, else CHALLENGE the lowest `game_id', a stable
%% tie-break so two seekers collide on one host rather than splitting.
-spec decide_role([map()], binary()) -> host | {challenge, binary(), binary()}.
decide_role(Heard, Me) ->
    lowest(lists:sort([{G, H} || #{game_id := G, host := H} <- Heard, H =/= Me])).

lowest([]) -> host;
lowest([{GameId, Host} | _]) -> {challenge, GameId, Host}.

%% @doc Given the last paddle arrival, when we paused (undefined if running),
%% now, and the timings: `ok', `pause', or `end_stale'.
-spec churn_action(integer(), integer() | undefined, integer(), map()) ->
    ok | pause | end_stale.
churn_action(LastMs, PausedSince, Now, Opts) ->
    #{stale_ms := Stale, grace_ms := Grace} = maps:merge(?DEFAULTS, Opts),
    staleness(Now - LastMs > Stale, PausedSince, Now, Grace).

staleness(false, _Since, _Now, _Grace) -> ok;
staleness(true, undefined, _Now, _Grace) -> pause;
staleness(true, Since, Now, Grace) when Now - Since > Grace -> end_stale;
staleness(true, _Since, _Now, _Grace) -> ok.

%%====================================================================
%% gen_server
%%====================================================================

init(Opts) ->
    process_flag(trap_exit, true),
    self() ! identify,
    self() ! read_stations,
    Now = now_ms(),
    {ok, #st{opts = maps:merge(defaults(), Opts), role_since = Now, unpaired_since = Now}}.

handle_call(status, _From, #st{role = Role, game_id = GameId, role_since = Since,
                               unpaired_since = Unpaired} = St) ->
    Now = now_ms(),
    {reply, #{role => Role, game_id => GameId, role_ms => Now - Since,
              unpaired_ms => unpaired_ms(Unpaired, Now)}, St}.

unpaired_ms(undefined, _Now) -> 0;
unpaired_ms(Since, Now) -> Now - Since.

handle_cast(_Msg, St) ->
    {noreply, St}.

%% Nothing is decided until we know who we are: our own facts come back to
%% us, and only our node id tells them apart.
handle_info(identify, #st{opts = #{node_id := NodeId}} = St) ->
    {noreply, identified(NodeId(), St)};

handle_info({seek_deadline, E}, #st{role = seeking, epoch = E, heard = Heard, me = Me} = St) ->
    {noreply, chosen(decide_role(Heard, Me), St)};

%% Keep the lobby tile alive while OPEN, so seekers find us, and while
%% PLAYING, so a restarted spectator rediscovers a game in progress.
handle_info({reannounce, E}, #st{role = Role, epoch = E} = St)
  when Role =:= hosting; Role =:= playing_host ->
    advertise(announced_status(Role), St),
    later(reannounce, St),
    {noreply, St};

handle_info({host_timeout, E}, #st{role = hosting, epoch = E} = St) ->
    advertise(withdrawn, St),
    {noreply, reseek(St)};

handle_info({challenge_timeout, E}, #st{role = challenging, epoch = E} = St) ->
    {noreply, reseek(St)};

handle_info({paddle_watchdog, E}, #st{role = playing_host, epoch = E, last_paddle_ms = Last,
                                 paused_since = Since, opts = Opts} = St) ->
    {noreply, churned(churn_action(Last, Since, now_ms(), Opts), St)};

handle_info({match_fact, Fact, Payload, #{publisher := Publisher} = Meta}, St) ->
    From = binary:encode_hex(Publisher, lowercase),
    Via = maps:get(delivered_via, Meta, undefined),
    {noreply, heard(From =:= St#st.me, Fact, mcl_mpong_facts:parse(Fact, Payload),
                    From, Via, St)};

handle_info(read_stations, #st{opts = #{stations := Read}} = St) ->
    Self = self(),
    _ = spawn(fun() -> Self ! {stations, Read()} end),
    erlang:send_after(maps:get(stations_ms, St#st.opts), self(), read_stations),
    {noreply, St};
handle_info({stations, Stations}, St) ->
    {noreply, stations_told(St#st{stations = Stations})};

%% Our engine ended: the match is over for us.
handle_info({'DOWN', Mon, process, _Pid, _Reason}, #st{engine = {_, Mon}} = St) ->
    advertise(ended, St),
    {noreply, reseek(St#st{engine = undefined})};
handle_info({'EXIT', Pid, _Reason}, #st{paddle = Pid} = St) ->
    {noreply, reseek(St#st{paddle = undefined})};
handle_info(_Stale, St) ->
    {noreply, St}.

%%====================================================================
%% Roles
%%====================================================================

%% The id every other bot and the spectator see as this bot's verified
%% publisher, logged once so an operator can tell the two bots apart.
identified({ok, NodeId}, St) ->
    Me = binary:encode_hex(NodeId, lowercase),
    logger:notice("[mpong] node id: ~s", [Me]),
    seeking(St#st{me = Me});
identified({error, _NotYet}, St) ->
    erlang:send_after(1000, self(), identify),
    St.

chosen(host, St) -> hosting(St);
chosen({challenge, GameId, Host}, St) -> challenging(GameId, Host, St).

seeking(St0) ->
    St = in_role(seeking, St0#st{game_id = undefined, peer = undefined, heard = [],
                                 last_paddle_ms = undefined, paused_since = undefined}),
    later(seek_deadline, jittered(seek_base_ms, seek_jitter_ms, St), St),
    St.

hosting(St0) ->
    St = in_role(hosting, St0#st{game_id = new_game_id(), heard = []}),
    advertise(open, St),
    later(reannounce, St),
    later(host_timeout, jittered(host_wait_base_ms, host_wait_jitter_ms, St), St),
    St.

challenging(GameId, Host, St0) ->
    St = in_role(challenging, St0#st{game_id = GameId, peer = Host, heard = []}),
    publish(seat_requested, mcl_mpong_facts:seat_requested(GameId, ?REMOTE_WALL, at_ms()), St),
    later(challenge_timeout, St),
    St.

%% The seat is ours to give: start the engine with the challenger on wall 1.
playing_host(Challenger, #st{game_id = GameId, opts = #{start_engine := Start}} = St0) ->
    publish(seat_reserved,
            mcl_mpong_facts:seat_reserved(GameId, Challenger, ?REMOTE_WALL, at_ms()), St0),
    {ok, Pid} = Start(#{game_id => GameId, emit => emitter(state_broadcast, St0)}),
    St = in_role(playing_host, St0#st{peer = Challenger,
                                      engine = {Pid, erlang:monitor(process, Pid)},
                                      last_paddle_ms = now_ms(), paused_since = undefined}),
    advertise(playing, St),
    later(paddle_watchdog, watchdog_ms, St),
    stations_told(St).

playing_remote(Wall, #st{game_id = GameId} = St0) ->
    {ok, Pid} = play_remote_paddle:start_link(#{game_id => GameId, wall_index => Wall,
                                                emit => emitter(paddle_moved, St0)}),
    stations_told(in_role(playing_remote, St0#st{paddle = Pid})).

reseek(#st{paddle = Paddle, engine = Engine} = St) ->
    stopped_paddle(Paddle),
    stopped_engine(Engine),
    seeking(St#st{paddle = undefined, engine = undefined}).

stopped_paddle(undefined) -> ok;
stopped_paddle(Pid) -> unlink(Pid), exit(Pid, shutdown), ok.

stopped_engine(undefined) -> ok;
stopped_engine({Pid, Mon}) -> erlang:demonitor(Mon, [flush]), exit(Pid, shutdown), ok.

in_role(Role, #st{unpaired_since = Unpaired, epoch = Epoch} = St) ->
    Now = now_ms(),
    St#st{role = Role, role_since = Now, epoch = Epoch + 1,
          unpaired_since = unpaired(Role, Unpaired, Now)}.

unpaired(playing_host, _Unpaired, _Now) -> undefined;
unpaired(playing_remote, _Unpaired, _Now) -> undefined;
unpaired(_Role, undefined, Now) -> Now;
unpaired(_Role, Since, _Now) -> Since.

announced_status(hosting) -> open;
announced_status(playing_host) -> playing.

%%====================================================================
%% Facts heard
%%====================================================================

%% Our own fact, or one that does not parse: nothing to act on.
heard(true, _Fact, _Parsed, _From, _Via, St) -> St;
heard(false, _Fact, {error, malformed}, _From, _Via, St) -> St;
heard(false, Fact, {ok, Parsed}, From, Via, St) -> on_fact(Fact, Parsed, From, Via, St).

%% SEEKING collects open games, but only an ad sent by the host it names.
on_fact(game_advertised, #{status := open, game_id := G, host_node_id := From}, From, _Via,
        #st{role = seeking, heard = Heard} = St) ->
    St#st{heard = [#{game_id => G, host => From} | Heard]};
%% Our host's game ended or was withdrawn.
on_fact(game_advertised, #{status := S, game_id := G}, From, _Via,
        #st{role = Role, game_id = G, peer = From} = St)
  when (S =:= ended orelse S =:= withdrawn),
       (Role =:= challenging orelse Role =:= playing_remote) ->
    reseek(St);
%% HOSTING: the first challenger to ask gets the seat.
on_fact(seat_requested, #{game_id := G}, From, _Via, #st{role = hosting, game_id = G} = St) ->
    playing_host(From, St);
%% PLAYING_HOST: the seat is taken, and saying so is a fact, not a silence.
on_fact(seat_requested, #{game_id := G}, From, _Via,
        #st{role = playing_host, game_id = G, peer = Peer} = St) when From =/= Peer ->
    publish(seat_denied, mcl_mpong_facts:seat_denied(G, From, seat_taken, at_ms()), St),
    St;
on_fact(seat_reserved, #{game_id := G, challenger_node_id := Me, wall_index := Wall}, From,
        _Via, #st{role = challenging, game_id = G, peer = From, me = Me} = St) ->
    playing_remote(Wall, St);
on_fact(seat_denied, #{game_id := G, challenger_node_id := Me}, From, _Via,
        #st{role = challenging, game_id = G, peer = From, me = Me} = St) ->
    reseek(St);
on_fact(paddle_moved, #{game_id := G} = Paddle, From, Via,
        #st{role = playing_host, game_id = G, peer = From, engine = {Pid, _}} = St) ->
    mpong_game_engine:remote_paddle(Pid, Paddle, Via),
    resumed(St#st.paused_since, Pid),
    St#st{last_paddle_ms = now_ms(), paused_since = undefined};
on_fact(state_broadcast, #{game_id := G} = Frame, From, Via,
        #st{role = playing_remote, game_id = G, peer = From, paddle = Pid} = St) ->
    play_remote_paddle:state_frame(Pid, Frame, Via),
    St;
on_fact(_Fact, _Parsed, _From, _Via, St) ->
    St.

resumed(undefined, _Pid) -> ok;
resumed(_Since, Pid) -> mpong_game_engine:resume(Pid).

churned(ok, St) ->
    later(paddle_watchdog, watchdog_ms, St),
    St;
churned(pause, #st{engine = {Pid, _}} = St) ->
    mpong_game_engine:pause(Pid),
    later(paddle_watchdog, watchdog_ms, St),
    St#st{paused_since = now_ms()};
%% Abandoned: stopping the engine brings its DOWN, which ends the game.
churned(end_stale, #st{engine = {Pid, _}} = St) ->
    exit(Pid, shutdown),
    St.

%%====================================================================
%% The mesh
%%====================================================================

advertise(Status, #st{game_id = GameId, me = Me} = St) ->
    publish(game_advertised, mcl_mpong_facts:game_advertised(GameId, Status, Me, at_ms()), St).

publish(Fact, Payload, #st{opts = #{publish := Publish}}) ->
    ok = Publish(Fact, Payload).

emitter(Fact, #st{opts = #{publish := Publish}}) ->
    fun(Payload) -> Publish(Fact, Payload) end.

%% Tell whichever end we are playing which stations we are on now.
stations_told(#st{engine = {Pid, _}, stations = Stations} = St) ->
    mpong_game_engine:stations(Pid, Stations),
    St;
stations_told(#st{paddle = Pid, stations = Stations} = St) when is_pid(Pid) ->
    play_remote_paddle:stations(Pid, Stations),
    St;
stations_told(St) ->
    St.

%%====================================================================
%% Defaults: the real mesh, through mcl_om
%%====================================================================

defaults() ->
    maps:merge(?DEFAULTS, #{node_id => fun self_node_id/0,
                            publish => fun publish_on_mesh/2,
                            stations => fun connected_stations/0,
                            start_engine => fun host_match_sup:start_engine/1}).

self_node_id() ->
    status_node_id(mcl_om:mesh_handles()).

status_node_id({ok, Pool, _Realm}) -> node_id_of(macula:status(Pool));
status_node_id({error, _} = NotYet) -> NotYet.

node_id_of({ok, #{self_node_id := NodeId}}) -> {ok, NodeId};
node_id_of(Other) -> {error, Other}.

%% The mesh being dark is not the match's problem to solve here; a refused
%% publish is logged by mcl_om (async_log), because a bot whose facts are
%% refused looks exactly like a bot nobody wants to play.
publish_on_mesh(Fact, Payload) ->
    _ = mcl_om_pubsub:publish(mcl_mpong_facts:topic(mcl_mpong_service:realm_name(), Fact),
                              Payload, #{mode => async_log}),
    ok.

connected_stations() ->
    links_of(mcl_om:mesh_handles()).

links_of({ok, Pool, _Realm}) -> stations_of(macula:links(Pool));
links_of({error, _}) -> [].

stations_of({ok, Links}) -> mesh_gauge:connected_stations(Links);
stations_of(_) -> [].

%%====================================================================
%% Helpers
%%====================================================================

%% A role timer, tagged with the epoch it was armed in.
later(Msg, #st{opts = Opts} = St) ->
    later(Msg, maps:get(timing_of(Msg), Opts), St).

later(Msg, Key, #st{opts = Opts} = St) when is_atom(Key) ->
    later(Msg, maps:get(Key, Opts), St);
later(Msg, Ms, #st{epoch = Epoch}) when is_integer(Ms) ->
    erlang:send_after(Ms, self(), {Msg, Epoch}).

timing_of(reannounce) -> reannounce_ms;
timing_of(challenge_timeout) -> challenge_wait_ms.

jittered(Base, Jitter, #st{opts = Opts}) ->
    maps:get(Base, Opts) + rand:uniform(maps:get(Jitter, Opts)).

new_game_id() ->
    binary:encode_hex(crypto:strong_rand_bytes(8), lowercase).

now_ms() -> erlang:monotonic_time(millisecond).

at_ms() -> erlang:system_time(millisecond).
