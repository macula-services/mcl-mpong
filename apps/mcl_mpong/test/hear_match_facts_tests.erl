%%% @doc The subscriber hands every match fact to the coordinator, untouched,
%%% with the meta macula verified it under.
-module(hear_match_facts_tests).

-include_lib("eunit/include/eunit.hrl").

forwards_the_fact_and_its_meta_to_the_coordinator_test() ->
    true = register(find_match, self()),
    try
        {ok, State} = hear_match_facts:init(paddle_moved),
        Meta = #{publisher => <<1:256>>, delivered_via => direct},
        ?assertEqual({noreply, State},
                     hear_match_facts:handle_event(<<"t">>, #{y => 1}, Meta, State)),
        %% Selective: eunit shares one process across modules, so other
        %% tests' messages may be waiting in this mailbox too.
        receive
            {match_fact, _, _, _} = Msg ->
                ?assertEqual({match_fact, paddle_moved, #{y => 1}, Meta}, Msg)
        after 500 -> error(nothing_forwarded)
        end
    after
        unregister(find_match)
    end.

%% Subscriptions come up before the coordinator does, and may outlive it in a
%% restart. A fact with nobody to hear it is dropped, not a crash that takes
%% the subscription down with it.
no_coordinator_is_not_a_crash_test() ->
    undefined = whereis(find_match),
    {ok, State} = hear_match_facts:init(state_broadcast),
    ?assertEqual({noreply, State},
                 hear_match_facts:handle_event(<<"t">>, #{}, #{}, State)).
