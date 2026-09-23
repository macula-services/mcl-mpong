%% @doc Supervises the bot: the engine supervisor, then the coordinator that
%% starts engines under it.
%%
%% `rest_for_one': if the engine supervisor goes, the coordinator is restarted
%% with it, since its monitor on a hosted engine went with it.
-module(mcl_mpong_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10},
          [#{id => host_match_sup,
             start => {host_match_sup, start_link, []},
             type => supervisor},
           #{id => find_match,
             start => {find_match, start_link, [#{name => find_match}]}}]}}.
