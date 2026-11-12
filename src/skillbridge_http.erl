-module(skillbridge_http).
-behaviour(gen_server).
-include_lib("kernel/include/file.hrl").
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(Port) -> gen_server:start_link({local, ?MODULE}, ?MODULE, [Port], []).
init([Port]) ->
    case gen_tcp:listen(Port, [binary, {packet, raw}, {active, false}, {reuseaddr, true},
                                {backlog, 128}, {ip, {127,0,0,1}}]) of
        {ok, Listen} -> logger:notice("SkillBridge listening on http://localhost:~B", [Port]),
                       self() ! accept, {ok, #{listen => Listen, port => Port}};
        {error, Reason} -> {stop, {listen_failed, Port, Reason}}
    end.
handle_call(_Request, _From, State) -> {reply, {error, unknown_request}, State}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(accept, #{listen := Listen} = State) ->
    case gen_tcp:accept(Listen, 1000) of
        {ok, Socket} -> _ = spawn(fun() -> handle_socket(Socket) end), self() ! accept,
                        {noreply, State};
        {error, timeout} -> self() ! accept, {noreply, State};
        {error, closed} -> {stop, normal, State};
        {error, _} -> erlang:send_after(100, self(), accept), {noreply, State}
    end;
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, #{listen := Listen}) -> gen_tcp:close(Listen), ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_socket(Socket) ->
    inet:setopts(Socket, [{active, false}, {recbuf, 16384}]),
    try
        case gen_tcp:recv(Socket, 0, 5000) of
            {ok, Packet} ->
                case read_request(Socket, Packet) of
                    {ok, Method, Path, Headers, Body} ->
                        {Status, Type, Response} = dispatch(Method, Path, Headers, Body),
                        send_response(Socket, Status, Type, Response);
                    {error, Why} -> json_response(Socket, 400, #{error => reason(Why)})
                end;
            {error, _} -> ok
        end
    catch _:_ -> json_response(Socket, 500, #{error => <<"Internal server error">>})
    after gen_tcp:close(Socket) end.

read_request(Socket, First) ->
    case binary:match(First, <<"\r\n\r\n">>) of
        nomatch when byte_size(First) < 65536 -> case gen_tcp:recv(Socket, 0, 5000) of
            {ok, More} -> read_request(Socket, <<First/binary, More/binary>>);
            Error -> Error end;
        nomatch -> {error, headers_too_large};
        {Pos, 4} -> HeaderBin = binary:part(First, 0, Pos),
                    BodyStart = binary:part(First, Pos + 4, byte_size(First) - Pos - 4),
                    parse_request(Socket, HeaderBin, BodyStart)
    end.
parse_request(Socket, HeaderBin, BodyStart) ->
    [RequestLine | HeaderLines] = binary:split(HeaderBin, <<"\r\n">>, [global]),
    case binary:split(RequestLine, <<" ">>, [global]) of
        [Method, Target | _] ->
            Headers = lists:foldl(fun header_pair/2, #{}, HeaderLines),
            Length = to_int(maps:get(<<"content-length">>, Headers, <<"0">>), 0),
            case Length >= 0 andalso Length =< 1048576 of
                false -> {error, body_too_large};
                true -> case read_body(Socket, BodyStart, Length) of
                    {ok, Body} -> [Path | _] = binary:split(Target, <<"?">>),
                                  {ok, Method, Path, Headers, Body};
                    Error -> Error end
            end;
        _ -> {error, invalid_request}
    end.
header_pair(Line, Acc) -> case binary:match(Line, <<":">>) of
    {Pos, 1} -> Key = lower(trim(binary:part(Line, 0, Pos))),
                Val = trim(binary:part(Line, Pos + 1, byte_size(Line) - Pos - 1)),
                Acc#{Key => Val};
    _ -> Acc end.
read_body(_Socket, Body, Length) when byte_size(Body) >= Length ->
    {ok, binary:part(Body, 0, Length)};
read_body(Socket, Body, Length) -> case gen_tcp:recv(Socket, Length - byte_size(Body), 5000) of
    {ok, More} -> read_body(Socket, <<Body/binary, More/binary>>, Length);
    Error -> Error end.

dispatch(<<"GET">>, <<"/api/health">>, _H, _B) -> {200, json, #{ok => true, name => <<"SkillBridge">>}};
dispatch(<<"OPTIONS">>, _Path, _H, _B) -> {204, text, <<>>};
dispatch(<<"GET">>, <<"/api/state">>, _H, _B) -> {200, json, skillbridge_store:snapshot()};
dispatch(<<"POST">>, <<"/api/session">>, H, B) -> with_body(H, B, fun(M) ->
    Email = lower(trim(maps:get(<<"email">>, M, <<>>))),
    case member_by_email(Email, skillbridge_store:get(members, [])) of
        {ok, Member} -> {200, json, Member};
        error -> {error, member_not_found}
    end end);
dispatch(<<"GET">>, <<"/api/members">>, _H, _B) -> {200, json, skillbridge_store:get(members, [])};
dispatch(<<"POST">>, <<"/api/members">>, H, B) -> with_body(H, B, fun(M) ->
    case skillbridge_store:add_member(M) of {ok, Member} -> {201, json, Member};
        {error, Why} -> {error, Why} end end);
dispatch(<<"POST">>, <<"/api/exchanges">>, H, B) -> with_body(H, B, fun(E) ->
    case skillbridge_store:create_exchange(E) of {ok, Exchange} -> {201, json, Exchange};
        {error, Why} -> {error, Why} end end);
dispatch(<<"POST">>, <<"/api/messages">>, H, B) -> with_body(H, B, fun(M) ->
    case skillbridge_store:send_message(M) of {ok, Message} -> {201, json, Message};
        {error, Why} -> {error, Why} end end);
dispatch(<<"POST">>, <<"/api/reports">>, H, B) -> with_body(H, B, fun(M) ->
    case skillbridge_store:report(maps:get(<<"memberId">>, M, <<>>), maps:get(<<"reporterId">>, M, <<>>)) of
        ok -> {201, json, #{ok => true}}; {error, Why} -> {error, Why} end end);
dispatch(<<"POST">>, Path, H, B) -> case path_id(Path, <<"/api/exchanges/">>, <<"/confirm">>) of
    {ok, Id} -> with_body(H, B, fun(M) ->
        case skillbridge_store:confirm_exchange(Id, maps:get(<<"memberId">>, M, <<>>)) of
            {ok, State} -> {200, json, State}; {error, Why} -> {error, Why} end end);
    error -> {404, json, #{error => <<"Route not found">>}}
end;
dispatch(<<"GET">>, Path, _H, _B) -> static_response(Path);
dispatch(_, _Path, _H, _B) -> {405, json, #{error => <<"Method not allowed">>}}.

with_body(H, B, Fun) ->
    case maps:get(<<"content-type">>, H, <<>>) of
        CT -> case binary:match(lower(CT), <<"application/json">>) of
            nomatch -> {415, json, #{error => <<"Send application/json">>}};
            _ -> try json_decode(B) of M when is_map(M) -> case Fun(M) of
                    {error, Why} -> {409, json, #{error => reason(Why)}};
                    Result -> Result end;
                _ -> {400, json, #{error => <<"Expected a JSON object">>}}
                catch _:_ -> {400, json, #{error => <<"Invalid JSON">>}} end
        end
    end.
json_decode(B) -> case erlang:function_exported(json, decode, 1) of
    true -> json:decode(B);
    false -> case erlang:function_exported(jsx, decode, 2) of
        true -> jsx:decode(B, [return_maps]);
        false -> case erlang:function_exported(jsone, decode, 1) of
            true -> jsone:decode(B);
            false -> skillbridge_json:decode(B) end
    end end.

static_response(<<"/">>) -> static_response(<<"/index.html">>);
static_response(Path) when byte_size(Path) < 256 ->
    case binary:match(Path, <<"..">>) of
        nomatch -> Root = filename:join(filename:absname("."), "priv/static"),
            File = filename:join(Root, binary_to_list(binary:part(Path, 1, byte_size(Path) - 1))),
            case filename:pathtype(File) =:= absolute andalso lists:prefix(Root, filename:absname(File)) of
                false -> {403, text, <<"Forbidden">>};
                true -> case file:read_file(File) of
                    {ok, Data} -> {200, content_type(File), Data};
                    _ -> case file:read_file(filename:join(Root, "index.html")) of
                        {ok, Index} when Path =/= <<"/favicon.svg">> -> {200, {raw, <<"text/html; charset=utf-8">>}, Index};
                        _ -> {404, text, <<"Not found">>}
                    end
                end
            end;
        _ -> {403, text, <<"Forbidden">>}
    end;
static_response(_) -> {404, text, <<"Not found">>}.
content_type(File) -> case string:lowercase(filename:extension(File)) of
    ".html" -> {raw, <<"text/html; charset=utf-8">>};
    ".css" -> {raw, <<"text/css; charset=utf-8">>};
    ".js" -> {raw, <<"text/javascript; charset=utf-8">>};
    ".svg" -> {raw, <<"image/svg+xml">>};
    ".png" -> {raw, <<"image/png">>};
    ".jpg" -> {raw, <<"image/jpeg">>};
    ".ico" -> {raw, <<"image/x-icon">>};
    _ -> {raw, <<"application/octet-stream">>}
end.
member_by_email(Email, Members) -> case [M || M <- Members,
    lower(maps:get(<<"email">>, M, <<>>)) =:= Email] of
    [Member | _] -> {ok, Member};
    [] -> error
end.
path_id(Path, Prefix, Suffix) ->
    PrefixSize = byte_size(Prefix), SuffixSize = byte_size(Suffix),
    case byte_size(Path) > PrefixSize + SuffixSize andalso
         binary:part(Path, 0, PrefixSize) =:= Prefix andalso
         binary:part(Path, byte_size(Path) - SuffixSize, SuffixSize) =:= Suffix of
        true -> {ok, binary:part(Path, PrefixSize, byte_size(Path) - PrefixSize - SuffixSize)};
        false -> error
    end.
send_response(Socket, Status, Type, Body) ->
    {CT, Data} = case Type of
        json -> {<<"application/json; charset=utf-8">>, iolist_to_binary(json_encode(Body))};
        text -> {<<"text/plain; charset=utf-8">>, iolist_to_binary(Body)};
        {raw, RawCT} -> {RawCT, iolist_to_binary(Body)}
    end,
    Reason = status_text(Status),
    Header = [<<"HTTP/1.1 ">>, integer_to_binary(Status), <<" ">>, Reason, <<"\r\n">>,
        <<"Content-Type: ">>, CT, <<"\r\nContent-Length: ">>, integer_to_binary(byte_size(Data)),
        <<"\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nCache-Control: no-cache\r\n">>,
        <<"Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\n\r\n">>],
    gen_tcp:send(Socket, [Header, Data]).
json_response(Socket, Status, Body) -> send_response(Socket, Status, json, Body).
status_text(200) -> <<"OK">>; status_text(201) -> <<"Created">>;
status_text(204) -> <<"No Content">>;
status_text(400) -> <<"Bad Request">>; status_text(403) -> <<"Forbidden">>;
status_text(404) -> <<"Not Found">>; status_text(405) -> <<"Method Not Allowed">>;
status_text(409) -> <<"Conflict">>; status_text(415) -> <<"Unsupported Media Type">>;
status_text(500) -> <<"Internal Server Error">>; status_text(_) -> <<"OK">>.
json_encode(Term) -> case erlang:function_exported(json, encode, 1) of
    true -> json:encode(Term);
    false -> case erlang:function_exported(jsx, encode, 1) of
        true -> jsx:encode(Term);
        false -> case erlang:function_exported(jsone, encode, 1) of
            true -> jsone:encode(Term);
            false -> skillbridge_json:encode(Term) end
    end end.
trim(B) -> unicode:characters_to_binary(string:trim(unicode:characters_to_list(B))).
lower(B) -> try unicode:characters_to_binary(string:lowercase(unicode:characters_to_list(B))) catch _:_ -> B end.
to_int(B, Default) -> try binary_to_integer(B) catch _:_ -> Default end.
reason(invalid_member) -> <<"Add your name, a valid email address, and your city. Keep your name and city under 80 characters.">>;
reason(invalid_email) -> <<"Enter a valid email address.">>;
reason(email_exists) -> <<"An account with this email address already exists.">>;
reason(member_not_found) -> <<"We could not find that member. Refresh and try again.">>;
reason(unknown_route) -> <<"Unknown API route.">>;
reason(same_member) -> <<"Choose a different member.">>;
reason(invalid_duration) -> <<"Exchanges must be between 1 and 8 hours.">>;
reason(insufficient_credits) -> <<"This member does not have enough time credits.">>;
reason(invalid_skill) -> <<"Enter a skill for this exchange.">>;
reason(invalid_message) -> <<"Messages must contain 1 to 1000 characters.">>;
reason(already_reported) -> <<"You have already reported this member.">>;
reason(exchange_not_found) -> <<"Exchange not found.">>;
reason(not_participant) -> <<"Only exchange participants can confirm it.">>;
reason(already_completed) -> <<"This exchange has already been settled.">>;
reason(Why) -> atom_to_binary(Why, utf8).
