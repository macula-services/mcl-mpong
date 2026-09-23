%%%-------------------------------------------------------------------
%%% @doc Collision detection for MPong (integer grid).
%%%
%%% Arena: 1000x1000. Left wall x=0, right wall x=1000.
%%% Paddles: position is 0-1000 along Y axis, height ~200.
%%% @end
%%%-------------------------------------------------------------------
-module(mpong_collision).

-export([check_paddle/3, check_miss/2]).

-define(ARENA_W, 1000).
-define(PADDLE_HALF_H, 55).  %% paddle covers 110 units (11% of arena)

%%--------------------------------------------------------------------
%% @doc Check if ball hit a paddle. Returns {bounce, Ball} or miss.
%%
%% Wall 0 = left (x=0), wall 1 = right (x=1000).
%% @end
%%--------------------------------------------------------------------
-spec check_paddle(mpong_ball:ball(), map(), map()) ->
    {bounced, mpong_ball:ball()} | no_bounce.
%% The two walls are mirror images, so they share one path: decide WHICH
%% wall the ball is reaching, then apply the same bounce maths to it. The
%% previous version nested the right wall inside the left wall's else
%% branch and duplicated the bounce arithmetic verbatim.
check_paddle(Ball, Paddles, Alive) ->
    #{x := Bx, y := By, vx := Vx, vy := Vy, r := R} = mpong_ball:to_map(Ball),
    bounce_off(reaching(Vx, Bx, R, Alive), By, Vx, Vy, R, Paddles).

%% Wall the ball is about to reach, if its player is still alive.
reaching(Vx, Bx, R, Alive) when Vx < 0, Bx - R =< 0 ->
    if_alive(0, Alive, wall);
reaching(Vx, Bx, R, Alive) when Vx > 0, Bx + R >= ?ARENA_W ->
    if_alive(1, Alive, wall);
reaching(_Vx, _Bx, _R, _Alive) ->
    none.

bounce_off(none, _By, _Vx, _Vy, _R, _Paddles) ->
    no_bounce;
bounce_off({wall, Wall}, By, Vx, Vy, R, Paddles) ->
    PaddleY = paddle_center(maps:get(Wall, Paddles, 500)),
    Offset = By - PaddleY,
    hit(abs(Offset) =< ?PADDLE_HALF_H, Wall, Offset, By, Vx, Vy, R).

hit(false, _Wall, _Offset, _By, _Vx, _Vy, _R) ->
    no_bounce;
hit(true, Wall, Offset, By, Vx, Vy, R) ->
    %% Reverse X, spin from the hit offset plus jitter (-2..+2), and speed
    %% up slightly on every bounce.
    NewVy = Vy + (Offset div 4) + (rand:uniform(5) - 3),
    NewVx = min(14, abs(Vx) + 1),
    {bounced, ball_off_wall(Wall, By, NewVx, NewVy, R, Offset)}.

ball_off_wall(0, By, NewVx, NewVy, R, Offset) ->
    set_ball(R + 1, By, NewVx, NewVy, R, Offset);
ball_off_wall(1, By, NewVx, NewVy, R, Offset) ->
    set_ball(?ARENA_W - R - 1, By, -NewVx, NewVy, R, Offset).

%%--------------------------------------------------------------------
%% @doc Check if ball passed a wall (miss → elimination).
%% @end
%%--------------------------------------------------------------------
-spec check_miss(mpong_ball:ball(), map()) -> {missed, non_neg_integer()} | none.
check_miss(Ball, Alive) ->
    #{x := Bx, r := R} = mpong_ball:to_map(Ball),
    past_wall({Bx - R =< -20, Bx + R >= ?ARENA_W + 20}, Alive).

past_wall({true, _}, Alive) -> if_alive(0, Alive, missed);
past_wall({_, true}, Alive) -> if_alive(1, Alive, missed);
past_wall(_Inside, _Alive)  -> none.

%% Tag a wall only while its player is alive; a dead wall is not a wall.
if_alive(Wall, Alive, Tag) ->
    case maps:get(Wall, Alive, false) of
        true  -> {Tag, Wall};
        false -> none
    end.

%%====================================================================
%% Internal
%%====================================================================

%% Paddle position (0-1000) is the center Y coordinate
paddle_center(Pos) -> Pos.

%% Construct a new ball state with spin and random power/dampen
set_ball(X, Y, Vx, Vy, R, Offset) ->
    %% Random power mechanic: 1-in-5 chance of power shot or soft touch
    {VxMod, VyMod} = case rand:uniform(10) of
        1 -> {3, 2};      %% SMASH — big speed boost
        2 -> {2, 1};      %% power shot
        9 -> {-3, -1};    %% soft touch — slow it down
        10 -> {-4, -2};   %% drop shot — very slow
        _ -> {0, 0}       %% normal
    end,
    Vx2 = Vx + sign(Vx) * VxMod,
    Vy2 = Vy + sign(Vy) * VyMod,
    %% Clamp speeds
    Vx3 = case abs(Vx2) < 5 of true -> sign(Vx2) * 5; false -> Vx2 end,
    Vx4 = case abs(Vx3) > 18 of true -> sign(Vx3) * 18; false -> Vx3 end,
    Vy3 = max(-14, min(14, Vy2)),
    %% Spin from paddle hit offset
    Spin = max(-3, min(3, Offset div 30)),
    mpong_ball:from_map(#{x => X, y => Y, vx => Vx4, vy => Vy3, r => R, spin => Spin}).

sign(X) when X >= 0 -> 1;
sign(_) -> -1.
