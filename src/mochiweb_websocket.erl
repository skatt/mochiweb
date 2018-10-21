-module(mochiweb_websocket).
-author('lukasz.lalik@zadane.pl').

%% The MIT License (MIT)

%% Copyright (c) 2012 Zadane.pl sp. z o.o.

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.

%% @doc Websockets module for Mochiweb. Based on Misultin websockets module.

-export([loop/5, upgrade_connection/2, request/5]).
-export([send/3]).
-ifdef(TEST).
-compile(export_all).
-endif.
loop({C,_} = Conn, Body, State, WsVersion, ReplyChannel) ->
    ok = mochiweb_util:exit_if_closed(C:setopts([{packet, 0}, {active, once}], Conn)),
    proc_lib:hibernate(?MODULE, request,
                       [Conn, Body, State, WsVersion, ReplyChannel]).

request({C,_} = Conn, Body, State, WsVersion, ReplyChannel) ->
    receive
        {tcp_closed, _} ->
            C:close(Conn),
            exit(normal);
        {ssl_closed, _} ->
            C:close(Conn),
            exit(normal);
        {tcp_error, _, _} ->
            C:close(Conn),
            exit(normal);
        {ssl_error, _, _Reason} ->
            C:close(Conn),
            exit(normal);
        {TcpOrSsl, _, WsFrames} when (TcpOrSsl =:= tcp) orelse (TcpOrSsl =:= ssl) ->
            case parse_frames(WsVersion, WsFrames, Conn) of
                close ->
                    C:close(Conn),
                    exit(normal);
                error ->
                    C:close(Conn),
                    exit(normal);
                Payload ->
                    NewState = call_body(Body, Payload, State, ReplyChannel),
                    loop(Conn, Body, NewState, WsVersion, ReplyChannel)
            end;
        _ ->
            C:close(Conn),
            exit(normal)
    end.

call_body({M, F, A}, Payload, State, ReplyChannel) ->
    erlang:apply(M, F, [Payload, State, ReplyChannel | A]);
call_body({M, F}, Payload, State, ReplyChannel) ->
    M:F(Payload, State, ReplyChannel);
call_body(Body, Payload, State, ReplyChannel) ->
    Body(Payload, State, ReplyChannel).

send({C,_} = Conn, {Type, Payload} = _Reply, hybi) ->
    Prefix = <<1:1, 0:3, (payload_type(Type)):4, (payload_length(iolist_size(Payload)))/binary>>,
    C:send([Prefix, Payload], Conn);
send({C,_} = Conn, {_Type, Payload} = _Reply, hixie) ->
    C:send([0, Payload, 255], Conn).

payload_type(text) -> 1;
payload_type(binary) -> 2.

upgrade_connection({R,_} = Req, Body) ->
    case make_handshake(Req) of
        {Version, Response} ->
            R:respond(Response, Req),
            Conn = R:get(connection, Req),
            ReplyChannel = fun(Reply) ->
                ?MODULE:send(Conn, Reply, Version)
            end,
            Reentry = fun (State) ->
                ?MODULE:loop(Conn, Body, State, Version, ReplyChannel)
            end,
            {Reentry, ReplyChannel};
        _ ->
            {R,_} = Req,
            Conn = R:get(connection, Req),
            {C,_} = Conn,
            C:close(Conn),
            exit(normal)
    end.

make_handshake({R,_} = Req) ->
    SecKey  = R:get_header_value("sec-websocket-key", Req),
    Sec1Key = R:get_header_value("Sec-WebSocket-Key1", Req),
    Sec2Key = R:get_header_value("Sec-WebSocket-Key2", Req),
    SubProto = R:get_header_value("Sec-Websocket-Protocol", Req),
    Origin = R:get_header_value(origin, Req),

    Result =
    if SecKey =/= undefined ->
            hybi_handshake(SecKey);
       Sec1Key =/= undefined andalso Sec2Key =/= undefined ->
            Host = R:get_header_value("Host", Req),
            Path = R:get(path, Req),
            Body = R:recv(8, Req),
            Scheme = scheme(Req),
            hixie_handshake(Scheme, Host, Path, Sec1Key, Sec2Key, Body, Origin);
       true ->
          error
    end,

    %%Subprotol
    case Result of
        {Version, Response = {Status, Headers, Data}} ->
            if 
                SubProto =:= undefined ->
                    {Version, Response};
                true ->
                    Response1 = {Status, Headers ++ [{"Sec-Websocket-Protocol", SubProto}], Data},
                    {Version, Response1}
            end;
        error -> 
            error
    end.

hybi_handshake(SecKey) ->
    BinKey = list_to_binary(SecKey),
    Bin = <<BinKey/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>,
    Challenge = base64:encode(crypto:hash(sha, Bin)),
    Response = {101, [{"Connection", "Upgrade"},
                      {"Upgrade", "websocket"},
                      {"Sec-Websocket-Accept", Challenge}], ""},
    {hybi, Response}.

scheme(Req) ->
    case mochiweb_request:get(scheme, Req) of
        http ->
            "ws://";
        https ->
            "wss://"
    end.

hixie_handshake(Scheme, Host, Path, Key1, Key2, Body, Origin) ->
    Ikey1 = [D || D <- Key1, $0 =< D, D =< $9],
    Ikey2 = [D || D <- Key2, $0 =< D, D =< $9],
    Blank1 = length([D || D <- Key1, D =:= 32]),
    Blank2 = length([D || D <- Key2, D =:= 32]),
    Part1 = erlang:list_to_integer(Ikey1) div Blank1,
    Part2 = erlang:list_to_integer(Ikey2) div Blank2,
    Ckey = <<Part1:4/big-unsigned-integer-unit:8,
            Part2:4/big-unsigned-integer-unit:8,
            Body/binary>>,
    Challenge = erlang:md5(Ckey),
    Location = lists:concat([Scheme, Host, Path]),
    Response = {101, [{"Upgrade", "WebSocket"},
                      {"Connection", "Upgrade"},
                      {"Sec-WebSocket-Origin", Origin},
                      {"Sec-WebSocket-Location", Location}],
                Challenge},
    {hixie, Response}.

parse_frames(hybi, Frames, Conn) ->
    try parse_hybi_frames(Conn, Frames, []) of
        Parsed -> process_frames(Parsed, [])
    catch
        _:_ -> error
    end;
parse_frames(hixie, Frames, _Conn) ->
    try parse_hixie_frames(Frames, []) of
        Payload -> Payload
    catch
        _:_ -> error
    end.

%%
%% Websockets internal functions for RFC6455 and hybi draft
%%
process_frames([], Acc) ->
    lists:reverse(Acc);
process_frames([{Opcode, Payload} | Rest], Acc) ->
    case Opcode of
        8 -> close;
        _ ->
            process_frames(Rest, [Payload | Acc])
    end.

parse_hybi_frames(_, <<>>, Acc) ->
    lists:reverse(Acc);

parse_hybi_frames(Conn, <<_Fin:1,
                          _Rsv:3,
                          Opcode:4,
                          _Mask:1,
                          PayloadLen:7,
                          MaskKey:4/binary,
                          Payload:PayloadLen/binary-unit:8,
                          Rest/binary>>,
                  Acc) when PayloadLen < 126 ->
    Payload2 = hybi_unmask(Payload, MaskKey, <<>>),
    parse_hybi_frames(Conn, Rest, [{Opcode, Payload2} | Acc]);

parse_hybi_frames(Conn, <<_Fin:1,
                          _Rsv:3,
                          Opcode:4,
                          _Mask:1,
                          126:7,
                          PayloadLen:16,
                          MaskKey:4/binary,
                          Payload:PayloadLen/binary-unit:8,
                          Rest/binary>>, Acc) ->
    Payload2 = hybi_unmask(Payload, MaskKey, <<>>),
    parse_hybi_frames(Conn, Rest, [{Opcode, Payload2} | Acc]);

parse_hybi_frames(Conn, <<_Fin:1,
                          _Rsv:3,
                          _Opcode:4,
                          _Mask:1,
                          126:7,
                          _PayloadLen:16,
                          _MaskKey:4/binary,
                          _/binary-unit:8>> = PartFrame, Acc) ->
    receive_more_frames(Conn, PartFrame, Acc);

parse_hybi_frames(Conn, <<_Fin:1,
                          _Rsv:3,
                          Opcode:4,
                          _Mask:1,
                          127:7,
                          0:1,
                          PayloadLen:63,
                          MaskKey:4/binary,
                          Payload:PayloadLen/binary-unit:8,
                          Rest/binary>>, Acc) ->
    Payload2 = hybi_unmask(Payload, MaskKey, <<>>),
    parse_hybi_frames(Conn, Rest, [{Opcode, Payload2} | Acc]);

parse_hybi_frames(Conn, <<_Fin:1,
                          _Rsv:3,
                          _Opcode:4,
                          _Mask:1,
                          127:7,
                          0:1,
                          _PayloadLen:63,
                          _MaskKey:4/binary,
                          _/binary-unit:8>> = PartFrame, Acc) ->
    receive_more_frames(Conn, PartFrame, Acc).

receive_more_frames({C,_} = Conn, PartFrame, Acc) ->
    ok = mochiweb_util:exit_if_closed(C:setopts([{packet, 0}, {active, once}], Conn)),
    receive
        {tcp_closed, _} ->
            C:close(Conn),
            exit(normal);
        {ssl_closed, _} ->
            C:close(Conn),
            exit(normal);
        {tcp_error, _, _} ->
            C:close(Conn),
            exit(normal);
        {ssl_error, _, _} ->
            C:close(Conn),
            exit(normal);
        {TcpOrSsl, _, Continuation} when (TcpOrSsl =:= tcp) orelse (TcpOrSsl =:= ssl) ->
            parse_hybi_frames(Conn, <<PartFrame/binary, Continuation/binary>>, Acc);
        _ ->
            C:close(Conn),
            exit(normal)
    after
        5000 ->
            C:close(Conn),
            exit(normal)
    end.

%% Unmasks RFC 6455 message
hybi_unmask(<<O:32, Rest/bits>>, MaskKey, Acc) ->
    <<MaskKey2:32>> = MaskKey,
    hybi_unmask(Rest, MaskKey, <<Acc/binary, (O bxor MaskKey2):32>>);
hybi_unmask(<<O:24>>, MaskKey, Acc) ->
    <<MaskKey2:24, _:8>> = MaskKey,
    <<Acc/binary, (O bxor MaskKey2):24>>;
hybi_unmask(<<O:16>>, MaskKey, Acc) ->
    <<MaskKey2:16, _:16>> = MaskKey,
    <<Acc/binary, (O bxor MaskKey2):16>>;
hybi_unmask(<<O:8>>, MaskKey, Acc) ->
    <<MaskKey2:8, _:24>> = MaskKey,
    <<Acc/binary, (O bxor MaskKey2):8>>;
hybi_unmask(<<>>, _MaskKey, Acc) ->
    Acc.

payload_length(N) ->
    case N of
        N when N =< 125 -> << N >>;
        N when N =< 16#ffff -> << 126, N:16 >>;
        N when N =< 16#7fffffffffffffff -> << 127, N:64 >>
    end.


%%
%% Websockets internal functions for hixie-76 websocket version
%%
parse_hixie_frames(<<>>, Frames) ->
  lists:reverse(Frames);
parse_hixie_frames(<<0, T/binary>>, Frames) ->
  {Frame, Rest} = parse_hixie(T, <<>>),
  parse_hixie_frames(Rest, [Frame | Frames]).

parse_hixie(<<255, Rest/binary>>, Buffer) ->
  {Buffer, Rest};
parse_hixie(<<H, T/binary>>, Buffer) ->
  parse_hixie(T, <<Buffer/binary, H>>).

