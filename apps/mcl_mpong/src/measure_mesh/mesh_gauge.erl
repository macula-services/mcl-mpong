%%% @doc What the match measures of the mesh. Pure: no process, no clock.
%%%
%%% Three gauges, each the answer to one question a spectator can ask of a
%%% match and get a true answer to:
%%%
%%%   sequence    how many numbered facts arrived, and how many in the span
%%%               did not (frames one way, moves the other)
%%%   round trip  how long a paddle move takes to come back acknowledged,
%%%               minus the time the host held it, so it is mesh time only
%%%   stations    which stations a pool is connected to right now
%%%
%%% Times are whatever monotonic milliseconds the caller reads; the gauge only
%%% subtracts its own caller's readings from each other.
-module(mesh_gauge).

-export([sequence/0, observe/2, seen/1, missed/1]).
-export([round_trip/0, sent/3, echoed/4, last/1, p50/1, samples/1, pending/1]).
-export([connected_stations/1, via/1]).

%% A seq this far behind the newest is too old to tell apart from a replay.
-define(DEDUP_SPAN, 256).
-define(RTT_WINDOW, 32).
-define(MAX_PENDING, 64).

-opaque sequence() :: #{seen := non_neg_integer(),
                        first := integer() | undefined,
                        last := integer() | undefined,
                        recent := #{integer() => []}}.
-opaque round_trip() :: #{pending := #{integer() => integer()},
                          samples := [non_neg_integer()]}.

-export_type([sequence/0, round_trip/0]).

%%------------------------------------------------------------------------------
%% Sequence
%%------------------------------------------------------------------------------

-spec sequence() -> sequence().
sequence() ->
    #{seen => 0, first => undefined, last => undefined, recent => #{}}.

-spec observe(integer(), sequence()) -> sequence().
observe(Seq, #{last := undefined} = G) ->
    G#{seen := 1, first := Seq, last := Seq, recent := #{Seq => []}};
observe(Seq, #{last := Last, recent := Recent} = G) ->
    counted(is_map_key(Seq, Recent) orelse Seq =< Last - ?DEDUP_SPAN, Seq, G).

counted(true, _Seq, G) ->
    G;
counted(false, Seq, #{seen := Seen, first := First, last := Last, recent := Recent} = G) ->
    NewLast = max(Last, Seq),
    Floor = NewLast - ?DEDUP_SPAN,
    G#{seen := Seen + 1, first := min(First, Seq), last := NewLast,
       recent := maps:filter(fun(S, _) -> S > Floor end, Recent#{Seq => []})}.

-spec seen(sequence()) -> non_neg_integer().
seen(#{seen := Seen}) -> Seen.

-spec missed(sequence()) -> non_neg_integer().
missed(#{last := undefined}) -> 0;
missed(#{seen := Seen, first := First, last := Last}) -> max(0, Last - First + 1 - Seen).

%%------------------------------------------------------------------------------
%% Round trip
%%------------------------------------------------------------------------------

-spec round_trip() -> round_trip().
round_trip() ->
    #{pending => #{}, samples => []}.

%% @doc Move `Seq' left at `NowMs'. The oldest unanswered moves are dropped
%% past a bound, so a host that never echoes costs nothing over a long match.
-spec sent(integer(), integer(), round_trip()) -> round_trip().
sent(Seq, NowMs, #{pending := Pending} = G) ->
    G#{pending := bounded(Pending#{Seq => NowMs})}.

bounded(Pending) when map_size(Pending) =< ?MAX_PENDING -> Pending;
bounded(Pending) -> bounded(maps:remove(lists:min(maps:keys(Pending)), Pending)).

%% @doc The host echoed `Seq' at `NowMs', having held it `HeldMs'. The host
%% echoes the latest move it applied, so every move up to `Seq' is settled.
-spec echoed(integer(), integer(), integer(), round_trip()) -> round_trip().
echoed(Seq, HeldMs, NowMs, #{pending := Pending} = G) ->
    measured(maps:find(Seq, Pending), Seq, HeldMs, NowMs, G).

measured(error, _Seq, _HeldMs, _NowMs, G) ->
    G;
measured({ok, SentAt}, Seq, HeldMs, NowMs, #{pending := Pending, samples := Samples} = G) ->
    Sample = max(0, NowMs - SentAt - HeldMs),
    G#{pending := maps:filter(fun(S, _) -> S > Seq end, Pending),
       samples := lists:sublist([Sample | Samples], ?RTT_WINDOW)}.

-spec last(round_trip()) -> non_neg_integer().
last(#{samples := [Newest | _]}) -> Newest;
last(#{samples := []}) -> 0.

-spec p50(round_trip()) -> non_neg_integer().
p50(#{samples := []}) -> 0;
p50(#{samples := Samples}) -> lists:nth((length(Samples) + 1) div 2, lists:sort(Samples)).

-spec samples(round_trip()) -> non_neg_integer().
samples(#{samples := Samples}) -> length(Samples).

-spec pending(round_trip()) -> non_neg_integer().
pending(#{pending := Pending}) -> map_size(Pending).

%%------------------------------------------------------------------------------
%% Stations
%%------------------------------------------------------------------------------

%% @doc The lowercase hex node ids of the connected links in a
%% `macula:links/1' answer, sorted, so two snapshots of one set compare equal.
-spec connected_stations([map()]) -> [binary()].
connected_stations(Links) ->
    lists:usort([binary:encode_hex(Id, lowercase)
                 || #{connected := true, node_id := Id} <- Links, is_binary(Id)]).

%% @doc How a fact reached this node, as the text the contract carries.
-spec via(atom()) -> binary().
via(direct)   -> <<"direct">>;
via(plumtree) -> <<"plumtree">>;
via(_)        -> <<"none">>.
