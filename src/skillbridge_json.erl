-module(skillbridge_json).
-export([decode/1, encode/1]).

decode(Binary) when is_binary(Binary) ->
    {Value, Rest} = value(skip_space(Binary)),
    case skip_space(Rest) of
        <<>> -> Value;
        _ -> erlang:error(trailing_json_data)
    end.

encode(Value) -> unicode:characters_to_binary(write(Value)).

value(<<$", Rest/binary>>) -> string_value(Rest, []);
value(<<${, Rest/binary>>) -> object_value(skip_space(Rest), #{});
value(<<$[, Rest/binary>>) -> array_value(skip_space(Rest), []);
value(<<$t, $r, $u, $e, Rest/binary>>) -> {true, Rest};
value(<<$f, $a, $l, $s, $e, Rest/binary>>) -> {false, Rest};
value(<<$n, $u, $l, $l, Rest/binary>>) -> {null, Rest};
value(<<C, _/binary>> = Binary) when C =:= $-; C >= $0, C =< $9 -> number_value(Binary);
value(_) -> erlang:error(invalid_json_value).

object_value(<<$}, Rest/binary>>, Acc) -> {Acc, Rest};
object_value(<<$\", Rest/binary>>, Acc) ->
    {Key, AfterKey} = string_value(Rest, []),
    case skip_space(AfterKey) of
        <<$:, AfterColon/binary>> ->
            {Item, AfterValue} = value(skip_space(AfterColon)),
            Updated = Acc#{Key => Item},
            case skip_space(AfterValue) of
                <<$,, Tail/binary>> -> object_value(skip_space(Tail), Updated);
                <<$}, Tail/binary>> -> {Updated, Tail};
                _ -> erlang:error(invalid_json_object)
            end;
        _ -> erlang:error(invalid_json_object)
    end;
object_value(_, _) -> erlang:error(invalid_json_object).

array_value(<<$], Rest/binary>>, Acc) -> {lists:reverse(Acc), Rest};
array_value(Binary, Acc) ->
    {Item, AfterItem} = value(Binary),
    case skip_space(AfterItem) of
        <<$,, Rest/binary>> -> array_value(skip_space(Rest), [Item | Acc]);
        <<$], Rest/binary>> -> {lists:reverse([Item | Acc]), Rest};
        _ -> erlang:error(invalid_json_array)
    end.

string_value(<<$\", Rest/binary>>, Acc) ->
    {unicode:characters_to_binary(lists:reverse(Acc)), Rest};
string_value(<<$\\, $\", Rest/binary>>, Acc) -> string_value(Rest, [$\" | Acc]);
string_value(<<$\\, $\\, Rest/binary>>, Acc) -> string_value(Rest, [$\\ | Acc]);
string_value(<<$\\, $/, Rest/binary>>, Acc) -> string_value(Rest, [$/ | Acc]);
string_value(<<$\\, $b, Rest/binary>>, Acc) -> string_value(Rest, [8 | Acc]);
string_value(<<$\\, $f, Rest/binary>>, Acc) -> string_value(Rest, [12 | Acc]);
string_value(<<$\\, $n, Rest/binary>>, Acc) -> string_value(Rest, [10 | Acc]);
string_value(<<$\\, $r, Rest/binary>>, Acc) -> string_value(Rest, [13 | Acc]);
string_value(<<$\\, $t, Rest/binary>>, Acc) -> string_value(Rest, [9 | Acc]);
string_value(<<$\\, $u, A, B, C, D, Rest/binary>>, Acc) ->
    try list_to_integer([A, B, C, D], 16) of
        Codepoint when Codepoint >= 16#D800, Codepoint =< 16#DBFF ->
            case Rest of
                <<$\\, $u, E, F, G, H, Tail/binary>> ->
                    Low = list_to_integer([E, F, G, H], 16),
                    case Low >= 16#DC00 andalso Low =< 16#DFFF of
                        true -> Full = 16#10000 + ((Codepoint - 16#D800) bsl 10) + (Low - 16#DC00),
                                string_value(Tail, [Full | Acc]);
                        false -> erlang:error(invalid_unicode_escape)
                    end;
                _ -> erlang:error(invalid_unicode_escape)
            end;
        Codepoint when Codepoint >= 16#DC00, Codepoint =< 16#DFFF ->
            erlang:error(invalid_unicode_escape);
        Codepoint -> string_value(Rest, [Codepoint | Acc])
    catch _:_ -> erlang:error(invalid_unicode_escape) end;
string_value(<<C/utf8, Rest/binary>>, Acc) when C >= 16#20 -> string_value(Rest, [C | Acc]);
string_value(_, _) -> erlang:error(invalid_json_string).

number_value(Binary) ->
    {Length, _} = number_end(Binary, 0),
    <<Number:Length/binary, Rest/binary>> = Binary,
    Value = try binary_to_integer(Number) catch _:_ ->
        try binary_to_float(normalise_float(Number)) catch _:_ -> erlang:error(invalid_json_number) end
    end,
    {Value, Rest}.

number_end(<<C, Rest/binary>>, N) when C >= $0, C =< $9 -> number_end(Rest, N + 1);
number_end(<<C, Rest/binary>>, N) when C =:= $-; C =:= $+; C =:= $.; C =:= $e; C =:= $E -> number_end(Rest, N + 1);
number_end(_, N) when N > 0 -> {N, done};
number_end(_, _) -> erlang:error(invalid_json_number).

normalise_float(Binary) ->
    HasDot = binary:match(Binary, <<".">>) =/= nomatch,
    Exp = max(binary:match(Binary, <<"e">>), binary:match(Binary, <<"E">>)),
    case {HasDot, Exp} of
        {true, _} -> Binary;
        {false, nomatch} -> <<Binary/binary, ".0">>;
        {false, {Pos, 1}} -> <<(binary:part(Binary, 0, Pos))/binary, ".0", (binary:part(Binary, Pos, byte_size(Binary) - Pos))/binary>>
    end.

skip_space(<<C, Rest/binary>>) when C =:= 32; C =:= 9; C =:= 10; C =:= 13 -> skip_space(Rest);
skip_space(Binary) -> Binary.

write(null) -> "null";
write(true) -> "true";
write(false) -> "false";
write(Value) when is_integer(Value) -> integer_to_binary(Value);
write(Value) when is_float(Value) -> float_to_binary(Value, [short]);
write(Value) when is_binary(Value) -> [<<$\">>, string_write(unicode:characters_to_list(Value)), <<$\">>];
write(Value) when is_atom(Value) -> write(atom_to_binary(Value, utf8));
write(Value) when is_list(Value) -> [<<$[>>, join([write(Item) || Item <- Value], <<$,>>), <<$]>>];
write(Value) when is_map(Value) ->
    Pairs = [[write(to_binary(Key)), <<$:>>, write(Item)] || {Key, Item} <- maps:to_list(Value)],
    [<<${>>, join(Pairs, <<$,>>), <<$}>>];
write(_) -> erlang:error(unsupported_json_value).

string_write([]) -> [];
string_write([$\" | Rest]) -> [<<$\\, $\">> | string_write(Rest)];
string_write([$\\ | Rest]) -> [<<$\\, $\\>> | string_write(Rest)];
string_write([8 | Rest]) -> [<<$\\, $b>> | string_write(Rest)];
string_write([12 | Rest]) -> [<<$\\, $f>> | string_write(Rest)];
string_write([10 | Rest]) -> [<<$\\, $n>> | string_write(Rest)];
string_write([13 | Rest]) -> [<<$\\, $r>> | string_write(Rest)];
string_write([9 | Rest]) -> [<<$\\, $t>> | string_write(Rest)];
string_write([C | Rest]) when C < 16#20 ->
    [io_lib:format("\\u~4.16.0b", [C]) | string_write(Rest)];
string_write([C | Rest]) -> [unicode:characters_to_binary([C]) | string_write(Rest)].

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(_) -> erlang:error(invalid_json_object_key).

join([], _) -> [];
join([First | Rest], Separator) -> [First | [[Separator, Item] || Item <- Rest]].
