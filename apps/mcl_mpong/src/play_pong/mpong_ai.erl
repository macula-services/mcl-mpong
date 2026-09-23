%%%-------------------------------------------------------------------
%%% @doc AI for an MPong paddle (integer grid).
%%%
%%% A paddle is steered by a personality: how fast it moves, how far off
%%% centre it aims for spin, how often and how badly it errs, and how hard it
%%% drifts back to the middle. Each paddle draws one with `personality/0' when
%%% its game starts and keeps it, so a wall plays in one style for a match.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_ai).

-export([personality/0, compute_paddle_position/4]).

-type personality() :: #{speed := pos_integer(), bias_range := non_neg_integer(),
                         err_rate := pos_integer(), err_mag := pos_integer(),
                         aggression := pos_integer()}.

-export_type([personality/0]).

%% @doc A random playing style, drawn once per paddle per game.
-spec personality() -> personality().
personality() ->
    #{speed => 9 + rand:uniform(3),
      bias_range => rand:uniform(40),
      err_rate => 8 + rand:uniform(8),
      err_mag => 25 + rand:uniform(25),
      aggression => 2 + rand:uniform(3)}.

%% @doc Where wall `WallIndex''s paddle goes next, given the ball.
-spec compute_paddle_position(map(), integer(), non_neg_integer(), personality()) -> integer().
compute_paddle_position(#{y := BallY, vx := BallVx}, CurrentY, WallIndex,
                        #{speed := Speed, bias_range := BiasRange, err_rate := ErrRate,
                          err_mag := ErrMag, aggression := Aggression}) ->
    Bias = bias(BiasRange),
    Target = target(approaching(WallIndex, BallVx), BallY, CurrentY, Bias, Aggression),
    Target2 = erring(rand:uniform(ErrRate), Target, ErrMag),
    Move = max(-Speed, min(Speed, Target2 - CurrentY)),
    max(70, min(930, CurrentY + Move)).

%%====================================================================
%% Internal
%%====================================================================

%% Aim off centre for spin, within the personality's range.
bias(0) -> 0;
bias(BiasRange) -> (rand:uniform(3) - 2) * BiasRange.

approaching(0, Vx) -> Vx < 0;
approaching(1, Vx) -> Vx > 0.

%% Track the ball when it is coming, drift to the centre when it is not.
target(true, BallY, _CurrentY, Bias, _Aggression) ->
    BallY + Bias;
target(false, _BallY, CurrentY, Bias, Aggression) ->
    CurrentY + (500 + (Bias div 2) - CurrentY) div Aggression.

%% An occasional mistake, one draw in `err_rate'.
erring(1, Target, ErrMag) -> Target + (rand:uniform(ErrMag * 2 + 1) - ErrMag - 1);
erring(_, Target, _ErrMag) -> Target.
