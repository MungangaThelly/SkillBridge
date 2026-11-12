-module(skillbridge_store).
-behaviour(gen_server).
-export([start_link/0, snapshot/0, get/2, add_member/1, create_exchange/1,
         confirm_exchange/2, send_message/1, report/2, data_file/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
snapshot() -> gen_server:call(?MODULE, snapshot).
get(Key, Default) -> gen_server:call(?MODULE, {get, Key, Default}).
add_member(Member) -> gen_server:call(?MODULE, {add_member, Member}).
create_exchange(Exchange) -> gen_server:call(?MODULE, {create_exchange, Exchange}).
confirm_exchange(Id, MemberId) -> gen_server:call(?MODULE, {confirm_exchange, Id, MemberId}).
send_message(Message) -> gen_server:call(?MODULE, {send_message, Message}).
report(MemberId, ReporterId) -> gen_server:call(?MODULE, {report, MemberId, ReporterId}).

data_file() ->
    case os:getenv("SKILLBRIDGE_DATA") of
        false -> filename:join([filename:absname("."), "data", "skillbridge.dets"]);
        Path -> filename:join(Path, "skillbridge.dets")
    end.

init([]) ->
    process_flag(trap_exit, true),
    File = data_file(),
    ok = filelib:ensure_dir(File),
    case dets:open_file(skillbridge_data, [{file, File}, {type, set}, {repair, true}]) of
        {ok, _} ->
            case dets:lookup(skillbridge_data, app_state) of
                [] -> State = seed(), ok = dets:insert(skillbridge_data, {app_state, State}),
                      {ok, State};
                [{app_state, State}] -> {ok, State}
            end;
        {error, Reason} -> {stop, {could_not_open_data_file, File, Reason}}
    end.

handle_call(snapshot, _From, State) -> {reply, public_state(State), State};
handle_call({get, Key, Default}, _From, State) -> {reply, maps:get(Key, State, Default), State};
handle_call({add_member, Member0}, _From, State) ->
    Members = maps:get(members, State),
    Email = lower(maps:get(<<"email">>, Member0, <<>>)),
    case valid_member(Member0) of
        false -> {reply, {error, invalid_member}, State};
        true when Email =:= <<>> -> {reply, {error, invalid_email}, State};
        true -> case is_email(Email) of
            false -> {reply, {error, invalid_email}, State};
            true -> case lists:any(fun(M) -> lower(maps:get(<<"email">>, M, <<>>)) =:= Email end, Members) of
            true -> {reply, {error, email_exists}, State};
            false ->
                Id = id(),
                Member = #{<<"id">> => Id, <<"name">> => clean(maps:get(<<"name">>, Member0)),
                    <<"email">> => Email, <<"city">> => clean(maps:get(<<"city">>, Member0)),
                    <<"bio">> => clean(maps:get(<<"bio">>, Member0, <<>>)),
                    <<"offers">> => normalise_list(maps:get(<<"offers">>, Member0, <<>>)),
                    <<"seeks">> => normalise_list(maps:get(<<"seeks">>, Member0, <<>>)),
                    <<"credits">> => 3, <<"rating">> => 5.0,
                    <<"joined">> => iso_date(), <<"reports">> => 0},
                New = State#{members => [Member | Members]},
                commit(New), {reply, {ok, Member}, New}
            end
        end
    end;
handle_call({create_exchange, E0}, _From, State) ->
    From = maps:get(<<"from">>, E0, <<>>), To = maps:get(<<"to">>, E0, <<>>),
    Duration = to_int(maps:get(<<"duration">>, E0, <<"1">>), 0),
    Members = maps:get(members, State),
    case {From =/= To, Duration >= 1 andalso Duration =< 8,
          member(From, Members), member(To, Members)} of
        {true, true, {ok, A}, {ok, B}} ->
            case maps:get(<<"credits">>, B, 0) >= Duration of
                false -> {reply, {error, insufficient_credits}, State};
                true ->
                    Exchange = #{<<"id">> => id(), <<"from">> => From, <<"to">> => To,
                        <<"skill">> => clean(maps:get(<<"skill">>, E0, <<>>)),
                        <<"duration">> => Duration, <<"date">> => iso_date(),
                        <<"status">> => <<"pending">>, <<"from_confirmed">> => false,
                        <<"to_confirmed">> => false,
                        <<"from_name">> => maps:get(<<"name">>, A),
                        <<"to_name">> => maps:get(<<"name">>, B)},
                    case maps:get(<<"skill">>, Exchange) of
                        <<>> -> {reply, {error, invalid_skill}, State};
                        _ -> New = State#{exchanges => [Exchange | maps:get(exchanges, State)]},
                             commit(New), {reply, {ok, Exchange}, New}
                    end
            end;
        {false, _, _, _} -> {reply, {error, same_member}, State};
        {_, false, _, _} -> {reply, {error, invalid_duration}, State};
        {_, _, error, _} -> {reply, {error, member_not_found}, State};
        {_, _, _, error} -> {reply, {error, member_not_found}, State}
    end;
handle_call({confirm_exchange, ExchangeId, MemberId}, _From, State) ->
    case update_exchange(ExchangeId, MemberId, State) of
        {error, Why} -> {reply, {error, Why}, State};
        {ok, New} -> commit(New), {reply, {ok, public_state(New)}, New}
    end;
handle_call({send_message, M0}, _From, State) ->
    From = maps:get(<<"from">>, M0, <<>>), To = maps:get(<<"to">>, M0, <<>>),
    Body = clean(maps:get(<<"body">>, M0, <<>>)),
    case {member(From, maps:get(members, State)), member(To, maps:get(members, State)),
          byte_size(Body) > 0 andalso byte_size(Body) =< 1000} of
        {{ok, Sender}, {ok, Recipient}, true} when From =/= To ->
            M = #{<<"id">> => id(), <<"from">> => From, <<"to">> => To,
                <<"from_name">> => maps:get(<<"name">>, Sender),
                <<"to_name">> => maps:get(<<"name">>, Recipient),
                <<"body">> => Body, <<"timestamp">> => timestamp()},
            New = State#{messages => lists:sublist([M | maps:get(messages, State)], 5000)},
            commit(New), {reply, {ok, M}, New};
        {error, _, _} -> {reply, {error, member_not_found}, State};
        {_, error, _} -> {reply, {error, member_not_found}, State};
        {_, _, false} -> {reply, {error, invalid_message}, State};
        _ -> {reply, {error, same_member}, State}
    end;
handle_call({report, Target, Reporter}, _From, State) ->
    case {member(Target, maps:get(members, State)), member(Reporter, maps:get(members, State))} of
        {{ok, _}, {ok, _}} when Target =/= Reporter ->
            Reports = maps:get(reports, State, []),
            case lists:member({Target, Reporter}, Reports) of
                true -> {reply, {error, already_reported}, State};
                false ->
                    Ms = [case maps:get(<<"id">>, M) =:= Target of
                        true -> M#{<<"reports">> => maps:get(<<"reports">>, M, 0) + 1};
                        false -> M end || M <- maps:get(members, State)],
                    New = State#{members => Ms, reports => [{Target, Reporter} | Reports]},
                    commit(New), {reply, ok, New}
            end;
        _ -> {reply, {error, member_not_found}, State}
    end;
handle_call(_Request, _From, State) -> {reply, {error, unknown_request}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> dets:close(skillbridge_data), ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

public_state(State) -> maps:without([reports], State).
commit(State) -> ok = dets:insert(skillbridge_data, {app_state, State}), ok = dets:sync(skillbridge_data).
member(Id, Members) -> case lists:dropwhile(fun(M) -> maps:get(<<"id">>, M) =/= Id end, Members) of
    [M | _] -> {ok, M}; [] -> error end.
update_exchange(ExchangeId, MemberId, State) ->
    Es = maps:get(exchanges, State),
    case lists:keyfind(ExchangeId, 1, [{maps:get(<<"id">>, E), E} || E <- Es]) of
        false -> {error, exchange_not_found};
        {_, E} ->
            From = maps:get(<<"from">>, E), To = maps:get(<<"to">>, E),
            case {MemberId =:= From orelse MemberId =:= To, maps:get(<<"status">>, E)} of
                {false, _} -> {error, not_participant};
                {_, <<"completed">>} -> {error, already_completed};
                {true, _} ->
                    E1 = case MemberId of
                        From -> E#{<<"from_confirmed">> => true};
                        To -> E#{<<"to_confirmed">> => true}
                    end,
                    Complete = maps:get(<<"from_confirmed">>, E1) andalso maps:get(<<"to_confirmed">>, E1),
                    case Complete of
                        false -> {ok, State#{exchanges => replace_exchange(E1, Es)}};
                        true -> settle(E1, State, Es)
                    end
            end
    end.
settle(E, State, Es) ->
    From = maps:get(<<"from">>, E), To = maps:get(<<"to">>, E),
    Duration = maps:get(<<"duration">>, E), Members = maps:get(members, State),
    case {member(From, Members), member(To, Members)} of
        {{ok, _A}, {ok, B}} -> case maps:get(<<"credits">>, B, 0) >= Duration of
            false -> {error, insufficient_credits};
            true ->
                Ms = [settled_member(M, From, To, Duration) || M <- Members],
                E1 = E#{<<"status">> => <<"completed">>, <<"completed_at">> => iso_date()},
                {ok, State#{members => Ms, exchanges => replace_exchange(E1, Es)}}
        end;
        _ -> {error, member_not_found}
    end.
settled_member(M, From, To, Duration) ->
    MemberId = maps:get(<<"id">>, M),
    case MemberId of
        From -> M#{<<"credits">> => maps:get(<<"credits">>, M, 0) + Duration};
        To -> M#{<<"credits">> => maps:get(<<"credits">>, M, 0) - Duration};
        _ -> M
    end.
replace_exchange(E, Es) -> [case maps:get(<<"id">>, X) =:= maps:get(<<"id">>, E) of true -> E; false -> X end || X <- Es].
valid_member(M) -> lists:all(fun(K) -> byte_size(clean(maps:get(K, M, <<>>))) > 0 end,
    [<<"name">>, <<"city">>, <<"email">>]) andalso
    byte_size(clean(maps:get(<<"name">>, M, <<>>))) =< 80 andalso
    byte_size(clean(maps:get(<<"city">>, M, <<>>))) =< 80 andalso
    byte_size(clean(maps:get(<<"email">>, M, <<>>))) =< 254 andalso
    byte_size(clean(maps:get(<<"bio">>, M, <<>>))) =< 360.
is_email(Email) ->
    case binary:split(Email, <<"@">>, [global]) of
        [Local, Domain] when byte_size(Local) > 0, byte_size(Domain) > 2 ->
            binary:match(Domain, <<".">>) =/= nomatch andalso
            binary:match(Email, <<" ">>) =:= nomatch;
        _ -> false
    end.
clean(B) when is_binary(B) -> trim(B);
clean(L) when is_list(L) -> clean(unicode:characters_to_binary(L));
clean(_) -> <<>>.
trim(B) -> unicode:characters_to_binary(string:trim(unicode:characters_to_list(B))).
lower(B) -> try unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(clean(B)))) catch _:_ -> clean(B) end.
normalise_list(B) -> [S || Part <- binary:split(clean(B), <<",">>, [global]),
    S <- [trim(Part)], S =/= <<>>, byte_size(S) =< 60].
to_int(I, _) when is_integer(I) -> I;
to_int(B, Default) when is_binary(B) -> try binary_to_integer(B) catch _:_ -> Default end;
to_int(_, Default) -> Default.
id() -> list_to_binary(binary_to_list(base64:encode(crypto:strong_rand_bytes(12), #{mode => urlsafe, padding => false}))).
iso_date() -> {{Y,M,D}, _} = calendar:universal_time(), iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0B", [Y,M,D])).
timestamp() -> {{Y,M,D},{H,Mi,S}} = calendar:universal_time(),
    iolist_to_binary(io_lib:format("~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ", [Y,M,D,H,Mi,S])).
seed() ->
    Members = [
      #{<<"id">> => <<"maria">>, <<"name">> => <<"Maria Chen">>, <<"email">> => <<"maria@example.local">>, <<"city">> => <<"Stockholm">>, <<"bio">> => <<"Bicycle mechanic who loves sharing practical skills. I can help you tune your bike or build confidence fixing it yourself.">>, <<"offers">> => [<<"Bicycle repair">>,<<"Basic woodworking">>], <<"seeks">> => [<<"English conversation">>,<<"Swedish practice">>], <<"credits">> => 4, <<"rating">> => 5.0, <<"joined">> => <<"2026-08-14">>, <<"reports">> => 0},
      #{<<"id">> => <<"jamie">>, <<"name">> => <<"Jamie Park">>, <<"email">> => <<"jamie@example.local">>, <<"city">> => <<"Stockholm">>, <<"bio">> => <<"Patient language tutor and neighbourhood gardener. Happy to practice English over a coffee or teach you to grow herbs on a balcony.">>, <<"offers">> => [<<"English conversation">>,<<"Gardening">>], <<"seeks">> => [<<"Bicycle repair">>,<<"Web design">>], <<"credits">> => 2, <<"rating">> => 4.9, <<"joined">> => <<"2026-07-22">>, <<"reports">> => 0},
      #{<<"id">> => <<"sam">>, <<"name">> => <<"Sam Okafor">>, <<"email">> => <<"sam@example.local">>, <<"city">> => <<"Stockholm">>, <<"bio">> => <<"A developer who believes everyone should feel welcome online. I can get you started with coding, your first website or conversational Swedish.">>, <<"offers">> => [<<"Programming">>,<<"Web design">>,<<"Swedish practice">>], <<"seeks">> => [<<"Bike maintenance">>,<<"Cooking">>], <<"credits">> => 6, <<"rating">> => 5.0, <<"joined">> => <<"2026-09-03">>, <<"reports">> => 0},
      #{<<"id">> => <<"elin">>, <<"name">> => <<"Elin Andersson">>, <<"email">> => <<"elin@example.local">>, <<"city">> => <<"Stockholm">>, <<"bio">> => <<"Home cook and confident cycle commuter. I can help you get comfortable in the kitchen and keep your bike rolling.">>, <<"offers">> => [<<"Cooking">>,<<"Bike maintenance">>], <<"seeks">> => [<<"Programming">>,<<"Photography">>], <<"credits">> => 3, <<"rating">> => 4.8, <<"joined">> => <<"2026-09-28">>, <<"reports">> => 0},
      #{<<"id">> => <<"luca">>, <<"name">> => <<"Luca Moretti">>, <<"email">> => <<"luca@example.local">>, <<"city">> => <<"Stockholm">>, <<"bio">> => <<"Neighbourhood photographer and former language student. I love making portraits approachable and finding the right words in a new language.">>, <<"offers">> => [<<"Photography">>,<<"English conversation">>], <<"seeks">> => [<<"Woodworking">>,<<"Gardening">>], <<"credits">> => 5, <<"rating">> => 5.0, <<"joined">> => <<"2026-10-12">>, <<"reports">> => 0}],
    #{members => Members, exchanges => [], messages => [], reports => []}.
