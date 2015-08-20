%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_odbc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Authentification via ODBC
%%% Created : 12 Dec 2004 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_auth_odbc).
-author('alexey@process-one.net').

-include("jlib.hrl").

%% External exports
-behaviour(ejabberd_gen_auth).
-export([start/1,
         stop/1,
         set_password/3,
         check_password/3,
         check_password/5,
         try_register/3,
         try_register/5,
         dirty_get_registered_users/0,
         get_vh_registered_users/1,
         get_vh_registered_users/2,
         get_vh_registered_users_number/1,
         get_vh_registered_users_number/2,
         get_password/2,
         get_password_s/2,
         is_user_exists/2,
         remove_user/2,
         remove_user/3,
         store_type/1,
         plain_password_required/0,
         phonelist_search/2,
         prepare_password/2,
         user_info/2,
         get_phone_email/3,
         update_phone/3
        ]).

-export([login/2, get_password/3]).

-export([scram_passwords/2, scram_passwords/4]).

-include("ejabberd.hrl").

-define(DEFAULT_SCRAMMIFY_COUNT, 10000).
-define(DEFAULT_SCRAMMIFY_INTERVAL, 1000).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

start(_Host) ->
    ok.

stop(_Host) ->
    ok.

plain_password_required() ->
    false.

store_type(Server) ->
    case scram:enabled(Server) of
        false -> plain;
        true -> scram
    end.

-spec check_password(User :: ejabberd:user(),
                     Server :: ejabberd:server(),
                     Password :: binary()) -> boolean().
check_password(User, Server, Password) ->
    case jlib:nodeprep(User) of
        error ->
            false;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            LServer = jlib:nameprep(Server),
            check_password_wo_escape(Username, LServer, Password)
    end.


-spec check_password(User :: ejabberd:user(),
                     Server :: ejabberd:server(),
                     Password :: binary(),
                     Digest :: binary(),
                     DigestGen :: fun()) -> boolean().
check_password(User, Server, Password, Digest, DigestGen) ->
    case jlib:nodeprep(User) of
        error ->
            false;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            LServer = jlib:nameprep(Server),
            try odbc_queries:get_password(LServer, Username) of
                %% Account exists, check if password is valid
                {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, Passwd, null}]} ->
                    ejabberd_auth:check_digest(Digest, DigestGen, Password, Passwd);
                {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, _Passwd, PassDetails}]} ->
                    case scram:deserialize(PassDetails) of
                        #scram{storedkey = StoredKey} ->
                            Passwd = base64:decode(StoredKey),
                            ejabberd_auth:check_digest(Digest, DigestGen, Password, Passwd);
                        _ ->
                            false
                    end;
                {selected, [<<"username">>, <<"password">>, <<"pass_details">>], []} ->
                    false; %% Account does not exist
                {error, _Error} ->
                    false %% Typical error is that table doesn't exist
            catch
                _:_ ->
                    false %% Typical error is database not accessible
            end
    end.

-spec check_password_wo_escape(User :: ejabberd:user(),
                               Server :: ejabberd:server(),
                               Password :: binary()) -> boolean() | not_exists.
check_password_wo_escape(User, Server, Password) ->
    try odbc_queries:get_password(Server, User) of
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, Password, null}]} ->
            Password /= <<"">>; %% Password is correct, and not empty
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, _Password2, null}]} ->
            false;
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, _Password2, PassDetails}]} ->
            case scram:deserialize(PassDetails) of
                {ok, #scram{} = Scram} ->
                    scram:check_password(Password, Scram);
                _ ->
                    false %% Password is not correct
            end;
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], []} ->
            false; %% Account does not exist
        {error, _Error} ->
            false %% Typical error is that table doesn't exist
    catch
        _:_ ->
            false %% Typical error is database not accessible
    end.


-spec set_password(User :: ejabberd:user(),
                   Server :: ejabberd:server(),
                   Password :: binary()
                               ) -> ok | {error, not_allowed | invalid_jid}.
set_password(User, Server, Password) ->
    case jlib:nodeprep(User) of
        error ->
            {error, invalid_jid};
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            LServer = jlib:nameprep(Server),
            case prepare_password(Server, Password) of
                false ->
                    {error, invalid_password};
                Pass ->
                    case catch odbc_queries:set_password_t(LServer, Username, Pass) of
                        {atomic, ok} ->
                            ok;
                        Other ->
                            {error, Other}
                    end
            end
    end.


-spec try_register(User :: ejabberd:user(),
                   Server :: ejabberd:server(),
                   Password :: binary()
                               ) -> {atomic, ok | exists}
                                        | {error, invalid_jid | not_allowed} | {aborted, _}.
try_register(User, Server, Password) ->
    case jlib:nodeprep(User) of
        error ->
            {error, invalid_jid};
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            case prepare_password(Server, Password) of
                false ->
                    {error, invalid_password};
                Pass ->
                    LServer = jlib:nameprep(Server),
                    case catch odbc_queries:add_user(LServer, Username, Pass) of
                        {updated, 1} ->
                            {atomic, ok};
                        _ ->
                            {atomic, exists}
                    end
            end
    end.


try_register(Username, Server, _Password, Phone, Nick) ->
    Nickname = ejabberd_odbc:escape(Nick),
    Pass = {<<"">>, <<"">>},
    LServer = jlib:nameprep(Server),
    %% modify 'TEL' element about standard vcard format as:
    %% 1.only one 'TEL' in vcard; 2.keep 'NUMBER' in 'TEL', also keep 'HOME' and 'CELL' in 'TEL', other element ignored.
    %% vcard format: <VCARD> <TEL> <NUMBER>1388888888</NUMBER> </TEL> ...</VCARD>
    VCardXml = {xmlel, <<"vCard">>,
        [{<<"xmlns">>, ?NS_VCARD}],
        [{xmlel, <<"NICKNAME">>, [], [{xmlcdata, Nickname}]},
         {xmlel, <<"TEL">>, [], [{xmlel, <<"HOME">>, [], []},
                                 {xmlel, <<"CELL">>, [], []},
                                 {xmlel, <<"NUMBER">>, [], [{xmlcdata, Phone}]}]}]},
    VcardTag = list_to_binary(jlib:md5_hex(xml:element_to_string2(VCardXml))),
    F = fun() ->
        case catch odbc_queries:add_user(LServer, Username, Pass, Phone, <<>>) of
            {updated, 1} ->
                {ok, VCardSearch} = mod_vcard:prepare_vcard_search_params(Username, LServer, VCardXml),
                mod_vcard_odbc:set_vcard_with_no_transaction(Username, LServer, VCardXml, VcardTag, VCardSearch),
                ok;
            _ ->
                exists
        end end,
    case ejabberd_odbc:sql_transaction(LServer, F) of
        {atomic, ok} ->
            ejabberd_hooks:run(vcard_set, LServer, [Username, LServer, VCardXml]),
            {atomic, ok};
        _ ->
            {atomic, exists}
    end.

-spec dirty_get_registered_users() -> [ejabberd:simple_jid()].
dirty_get_registered_users() ->
    Servers = ejabberd_config:get_vh_by_auth_method(odbc),
    lists:flatmap(
      fun(Server) ->
              get_vh_registered_users(Server)
      end, Servers).


-spec get_vh_registered_users(Server :: ejabberd:server()
                                        ) -> [ejabberd:simple_jid()].
get_vh_registered_users(Server) ->
    LServer = jlib:nameprep(Server),
    case catch odbc_queries:list_users(LServer) of
        {selected, [<<"username">>], Res} ->
            [{U, LServer} || {U} <- Res];
        _ ->
            []
    end.


-spec get_vh_registered_users(Server :: ejabberd:server(), Opts :: list()
                                                                   ) -> [ejabberd:simple_jid()].
get_vh_registered_users(Server, Opts) ->
    LServer = jlib:nameprep(Server),
    case catch odbc_queries:list_users(LServer, Opts) of
        {selected, [<<"username">>], Res} ->
            [{U, LServer} || {U} <- Res];
        _ ->
            []
    end.


-spec get_vh_registered_users_number(Server :: ejabberd:server()
                                               ) -> integer().
get_vh_registered_users_number(Server) ->
    LServer = jlib:nameprep(Server),
    case catch odbc_queries:users_number(LServer) of
        {selected, [_], [{Res}]} ->
            list_to_integer(binary_to_list(Res));
        _ ->
            0
    end.


-spec get_vh_registered_users_number(Server :: ejabberd:server(),
                                     Opts :: list()) -> integer().
get_vh_registered_users_number(Server, Opts) ->
    LServer = jlib:nameprep(Server),
    case catch odbc_queries:users_number(LServer, Opts) of
        {selected, [_], [{Res}]} ->
            list_to_integer(Res);
        _Other ->
            0
    end.

phonelist_search(PhoneList, LServer) ->
    lists:foldl(fun(E, R) ->
                        case catch ejabberd_odbc:sql_query(LServer, [<<"select username from users where cellphone='">>, E, <<"';">>]) of
                            {selected, [<<"username">>], [{UserName}]} ->
                                [{E, UserName} | R];
                            _ ->
                                R
                        end end, [], PhoneList).


-spec get_password(User :: ejabberd:user() | {phone, binary()} | {email, binary()},
                   Server :: ejabberd:server()) -> binary() | {ejabberd:user(), binary()} | false.
get_password({phone, Phone}, Server) ->
    do_get_password({phone, ejabberd_odbc:escape(Phone)}, Server);
get_password({email, Email}, Server) ->
    do_get_password({email, ejabberd_odbc:escape(Email)}, Server);
get_password(User, Server) ->
    case jlib:nodeprep(User) of
        error ->
            false;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            case do_get_password(Username, Server) of
                false -> false;
                {_, Password} -> Password
            end
    end.

do_get_password(User, Server) ->
    LServer = jlib:nameprep(Server),
    case catch odbc_queries:get_password(LServer, User) of
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{Username, <<>>, <<>>}]} ->
            false;
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{Username, Password, null}]} ->
            {Username, Password}; %%Plain password
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{Username, _Password, PassDetails}]} ->
            case scram:deserialize(PassDetails) of
                {ok, #scram{} = Scram} ->
                    {Username,
                     {base64:decode(Scram#scram.storedkey),
                      base64:decode(Scram#scram.serverkey),
                      base64:decode(Scram#scram.salt),
                      Scram#scram.iterationcount}
                    };
                _ ->
                    false
            end;
        _ ->
            false
    end.


-spec get_password_s(User :: ejabberd:user(),
                     Server :: ejabberd:server()) -> binary().
get_password_s(User, Server) ->
    case jlib:nodeprep(User) of
        error ->
            <<"">>;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            LServer = jlib:nameprep(Server),
            case catch odbc_queries:get_password(LServer, Username) of
                {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, Password, _}]} ->
                    Password;
                _ ->
                    <<"">>
            end
    end.

-spec is_user_exists(User :: ejabberd:user(),
                     Server :: ejabberd:server()
                               ) -> boolean() | {error, atom()}.
is_user_exists(User, Server) ->
    case jlib:nodeprep(User) of
        error ->
            false;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            LServer = jlib:nameprep(Server),
            try odbc_queries:get_password(LServer, Username) of
                {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{_, _Password, _}]} ->
                    true; %% Account exists
                {selected, [<<"username">>, <<"password">>, <<"pass_details">>], []} ->
                    false; %% Account does not exist
                {error, Error} ->
                    {error, Error} %% Typical error is that table doesn't exist
            catch
                _:B ->
                    {error, B} %% Typical error is database not accessible
            end
    end.


%% @doc Remove user.
%% Note: it may return ok even if there was some problem removing the user.
-spec remove_user(User :: ejabberd:user(),
                  Server :: ejabberd:server()
                            ) -> ok | error | {error, not_allowed}.
remove_user(User, Server) ->
    case jlib:nodeprep(User) of
        error ->
            error;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            LServer = jlib:nameprep(Server),
            catch odbc_queries:del_user(LServer, Username),
            ok
    end.


%% @doc Remove user if the provided password is correct.
-spec remove_user(User :: ejabberd:user(),
                  Server :: ejabberd:server(),
                  Password :: binary()
                              ) -> ok | not_exists | not_allowed | bad_request | error.
remove_user(User, Server, Password) ->
    case jlib:nodeprep(User) of
        error ->
            error;
        LUser ->
            Username = ejabberd_odbc:escape(LUser),
            Pass = ejabberd_odbc:escape(Password),
            LServer = jlib:nameprep(Server),
            case check_password_wo_escape(Username, LServer, Pass) of
                true ->
                    case catch odbc_queries:del_user(LServer, Username) of
                        {'EXIT', _} -> error;
                        _ -> ok
                    end;
                not_exists ->
                    not_exists;
                false ->
                    not_allowed
            end
    end.

%%%------------------------------------------------------------------
%%% SCRAM
%%%------------------------------------------------------------------

prepare_password(Iterations, Password) when is_integer(Iterations) ->
    Scram = scram:password_to_scram(Password, Iterations),
    case scram:serialize(Scram) of
        {error, _} ->
            false;
        PassDetails ->
            PassDetailsEscaped = ejabberd_odbc:escape(PassDetails),
            {<<"">>, PassDetailsEscaped}
    end;
prepare_password(Server, Password) ->
    case scram:enabled(Server) of
        true ->
            prepare_password(scram:iterations(Server), Password);
        _ ->
            ejabberd_odbc:escape(Password)
    end.

scram_passwords(Server, ScramIterationCount) ->
    scram_passwords(Server, ?DEFAULT_SCRAMMIFY_COUNT, ?DEFAULT_SCRAMMIFY_INTERVAL, ScramIterationCount).

scram_passwords(Server, Count, Interval, ScramIterationCount) ->
    LServer = jlib:nameprep(Server),
    ?INFO_MSG("Converting the stored passwords into SCRAM bits", []),
    ToConvertCount = case catch odbc_queries:get_users_without_scram_count(LServer) of
                         {selected, [_], [{Res}]} -> binary_to_integer(Res);
                         _ -> 0
                     end,

    ?INFO_MSG("Users to scrammify: ~p", [ToConvertCount]),
    scram_passwords1(LServer, Count, Interval, ScramIterationCount).

scram_passwords1(LServer, Count, Interval, ScramIterationCount) ->
    case odbc_queries:get_users_without_scram(LServer, Count) of
        {selected, _, []} ->
            ?INFO_MSG("All users scrammed.", []);
        {selected, [<<"username">>, <<"password">>], Results} ->
            ?INFO_MSG("Scramming ~p users...", [length(Results)]),
            lists:foreach(
              fun({Username, Password}) ->
                      Scrammed = prepare_password(ScramIterationCount, Password),
                      case catch odbc_queries:set_password_t(LServer, Username, Scrammed) of
                          {atomic, ok} -> ok;
                          Other -> ?ERROR_MSG("Could not scrammify user ~s@~s because: ~p", [Username, LServer, Other])
                      end
              end, Results),
            ?INFO_MSG("Scrammed. Waiting for ~pms", [Interval]),
            timer:sleep(Interval),
            scram_passwords1(LServer, Count, Interval, ScramIterationCount);
        Other ->
            ?ERROR_MSG("Interrupted scramming because: ~p", [Other])
    end.

%% @doc Unimplemented gen_auth callbacks
login(_User, _Server) -> erlang:error(not_implemented).
get_password(_User, _Server, _DefaultValue) -> erlang:error(not_implemented).

user_info(Server, Phone) ->
    LServer = jlib:nameprep(Server),
    Query = ["select username, password, pass_details from users where cellphone='"],
    try ejabberd_odbc:sql_query(LServer, [Query, Phone, "';"]) of
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], [{UserName, Password, PasswordDetails}]} ->
            {info, {UserName, Password, PasswordDetails}};
        {selected, [<<"username">>, <<"password">>, <<"pass_details">>], []} ->
            not_exist;
        {error, Error} ->
            {error, Error} %% Typical error is that table doesn't exist
    catch
        _:B -> {error, B} %% Typical error is database not accessible
    end.

get_phone_email(User, Server, IsPhone) ->
    LServer = jlib:nameprep(Server),
    LUser = jlib:nodeprep(User),

    Name = case IsPhone of
               true -> "cellphone";
               _ -> "email"
           end,
    Query = ["select ", Name, " from users where username='", LUser, "';"],
    case ejabberd_odbc:sql_query(LServer, Query) of
        %{selected, _, []} ->
        %    not_exist;
        {selected, _, [{<<>>}]} -> %% should not occur.
            false;
        {selected, _, [{null}]} -> %% should not occur.
            false;
        {selected, _, [{Result}]} ->
            Result;
        _ ->
            false
    end.

update_phone(Username, Server, Phone) ->
    LServer = jlib:nameprep(Server),
    LUser = jlib:nodeprep(Username),

    Query0 = ["select vcard from vcard where username='", LUser, "' and server='", LServer, "';"],
    Query1 = ["update users set cellphone='", Phone, "' where username='", LUser, "';"],
    F = fun() ->
        VCard = case ejabberd_odbc:sql_query_t(Query0) of
                                {selected, _, [{V}]} -> V;
                                _ -> <<>>
                end,
        NewVCard = update_vcard_number(VCard, Phone),
        VcardTag = list_to_binary(jlib:md5_hex(xml:element_to_string2(NewVCard))),
        {ok, VCardSearch} = mod_vcard:prepare_vcard_search_params(Username, LServer, NewVCard),
        case ejabberd_odbc:sql_query_t(Query1) of
            {updated, 1} ->
                mod_vcard_odbc:set_vcard_with_no_transaction(Username, LServer, NewVCard, VcardTag, VCardSearch),
                true;
            _ ->
                false
        end
    end,

    case ejabberd_odbc:sql_transaction(LServer, F) of
        {atomic, true} ->
            true;
        _ ->
            false
    end.

remove_element_children(#xmlel{children = Children}, Name) ->
    lists:filter(fun(E) ->
        case E of
            #xmlel{name=Name} -> false;
            _ -> true
        end
    end,
    Children).

update_vcard_number(VCard, Number) ->
    TelXmlEl = {xmlel, <<"TEL">>, [], [{xmlel, <<"HOME">>, [], []},
        {xmlel, <<"CELL">>, [], []},
        {xmlel, <<"NUMBER">>, [], [{xmlcdata, Number}]}]},

    case xml_stream:parse_element(VCard) of
        #xmlel{name = <<"vCard">>} = VCardXml ->
            FilterChildren = remove_element_children(VCardXml, <<"TEL">>),
            NewChildren = [TelXmlEl | FilterChildren],
            VCardXml#xmlel{children = NewChildren};
        _ ->
            {xmlel, <<"vCard">>,
                [{<<"xmlns">>, ?NS_VCARD}],
                [{xmlel, <<"TEL">>, [], [{xmlel, <<"HOME">>, [], []},
                                         {xmlel, <<"CELL">>, [], []},
                                         {xmlel, <<"NUMBER">>, [], [{xmlcdata, Number}]}]}]}
    end.
