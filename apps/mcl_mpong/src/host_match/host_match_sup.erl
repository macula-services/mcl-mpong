%%% @doc Supervises the engine of the match this bot hosts, while it hosts one.
%%%
%%% `temporary': a match that crashes is over, not restarted. `find_match'
%%% monitors the engine, announces the game ended, and looks for the next one.
-module(host_match_sup).

-behaviour(supervisor).

-export([start_link/0, start_engine/1, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec start_engine(map()) -> {ok, pid()} | {error, term()}.
start_engine(Config) ->
    supervisor:start_child(?MODULE, [Config]).

init([]) ->
    {ok, {#{strategy => simple_one_for_one, intensity => 10, period => 10},
          [#{id => mpong_game_engine,
             start => {mpong_game_engine, start_link, []},
             restart => temporary}]}}.
