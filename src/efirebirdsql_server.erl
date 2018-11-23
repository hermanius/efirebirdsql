%%% The MIT License (MIT)

%%% Copyright (c) 2016 Hajime Nakagami<nakagami@gmail.com>

-module(efirebirdsql_server).

-behavior(gen_server).

-export([start_link/0, get_parameter/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([init/1, code_change/3, terminate/2]).

-include("efirebirdsql.hrl").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Utility functions in module

connect_database(TcpMod, Sock, Username, Password, Database, PageSize, AcceptVersion, IsCreateDB, State) ->
    case IsCreateDB of
        true ->
            create_database(TcpMod, Sock, Username, Password, Database, PageSize, AcceptVersion, State);
        false ->
            attach_database(TcpMod, Sock, Username, Password, Database, AcceptVersion, State)
    end.

attach_database(TcpMod, Sock, User, Password, Database, AcceptVersion, State) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_attach(User, Password, Database, AcceptVersion)),
    R = case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response, {ok, Handle, _}} -> {ok, Handle};
        {op_response, {error, Msg}} ->{error, Msg}
    end,
    case R of
        {ok, DbHandle} ->
            case allocate_statement(TcpMod, Sock, DbHandle) of
                {ok, StmtHandle} ->
                    {ok, State#state{db_handle = DbHandle, stmt_handle = StmtHandle, accept_version = AcceptVersion}};
                {error, Msg2} ->
                    {{error, Msg2}, State#state{db_handle = DbHandle, accept_version = AcceptVersion}}
            end;
        {error, Msg3} ->
            {{error, Msg3}, State}
    end.

create_database(TcpMod, Sock, User, Password, Database, PageSize, AcceptVersion, State) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_create(User, Password, Database, PageSize, AcceptVersion)),
    R = case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response, {ok, Handle, _}} -> {ok, Handle};
        {op_response, {error, Msg}} ->{error, Msg}
    end,
    case R of
        {ok, DbHandle} ->
            case allocate_statement(TcpMod, Sock, DbHandle) of
                {ok, StmtHandle} ->
                    {ok, State#state{db_handle = DbHandle, stmt_handle = StmtHandle, accept_version = AcceptVersion}};
                {error, Msg2} ->
                    {{error, Msg2}, State#state{db_handle = DbHandle, accept_version = AcceptVersion}}
            end;
        {error, Msg3} ->
            {{error, Msg3}, State}
    end.

allocate_statement(TcpMod, Sock, DbHandle) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_allocate_statement(DbHandle)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response, {ok, Handle, _}} -> {ok, Handle};
        {op_response, {error, Msg}} ->{error, Msg}
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% handle functions

connect(TcpMod, Host, Username, Password, Database, IsCreateDB, PageSize, State) ->
    Sock = State#state.sock,
    TcpMod:send(Sock,
        efirebirdsql_op:op_connect(Host, Username, Password, Database, State#state.public_key, State#state.wire_crypt)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_accept, {AcceptVersion, _AcceptType}} ->
            connect_database(TcpMod, Sock, Username, Password, Database, PageSize, AcceptVersion, IsCreateDB, State);
        {op_cond_accept, {_AcceptVersion, _AcceptType}} ->
            io:format("op_cond_accept");
        {op_accept_data, {_AcceptVersion, _AcceptType}} ->
            io:format("op_accept_data");
        {op_reject, _} -> {{error, "Connection Rejected"}, State}
    end.

detach(TcpMod, Sock, DbHandle) ->
    TcpMod:send(Sock, efirebirdsql_op:op_detach(DbHandle)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response,  {ok, _, _}} -> ok;
        {op_response, {error, Msg}} -> {error, Msg}
    end.

%% Transaction
begin_transaction(TcpMod, Sock, DbHandle, Tpb) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_transaction(DbHandle, Tpb)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response,  {ok, Handle, _}} -> {ok, Handle};
        {op_response, {error, Msg}} -> {error, Msg}
    end.

%% prepare and free statement
prepare_statement(TcpMod, Sock, TransHandle, StmtHandle, Sql) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_prepare_statement(TransHandle, StmtHandle, Sql)),
    efirebirdsql_op:get_prepare_statement_response(TcpMod, Sock, StmtHandle).

free_statement(TcpMod, Sock, StmtHandle) ->
    TcpMod:send(Sock, efirebirdsql_op:op_free_statement(StmtHandle)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response,  {ok, _, _}} -> ok;
        {op_response, {error, Msg}} -> {error, Msg}
    end.

%% Execute, Fetch and Description
execute(TcpMod, Sock, TransHandle, StmtHandle, Params) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_execute(TransHandle, StmtHandle, Params)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response,  {ok, _, _}} -> ok;
        {op_response, {error, Msg}} -> {error, Msg}
    end.

execute2(TcpMod, Sock, TransHandle, StmtHandle, Param, XSqlVars) ->
        TcpMod:send(Sock,
            efirebirdsql_op:op_execute2(TransHandle, StmtHandle, Param, XSqlVars)),
        Row = efirebirdsql_op:get_sql_response(TcpMod, Sock, XSqlVars),
        case efirebirdsql_op:get_response(TcpMod, Sock) of
            {op_response,  {ok, _, _}} -> {ok, Row};
            {op_response, {error, Msg}} -> {error, Msg}
        end.

fetchrows(TcpMod, Sock, StmtHandle, XSqlVars, Results) ->
    TcpMod:send(Sock,
        efirebirdsql_op:op_fetch(StmtHandle, XSqlVars)),
    {op_fetch_response, {NewResults, MoreData}} = efirebirdsql_op:get_fetch_response(TcpMod, Sock, XSqlVars),
    case MoreData of
        true -> fetchrows(TcpMod, Sock,
            StmtHandle, XSqlVars,lists:flatten([Results, NewResults]));
        false -> {ok, Results ++ NewResults}
    end.
fetchrows(TcpMod, Sock, StmtHandle, XSqlVars) ->
    fetchrows(TcpMod, Sock, StmtHandle, XSqlVars, []).

description([], XSqlVar) ->
    lists:reverse(XSqlVar);
description(InXSqlVars, XSqlVar) ->
    [H | T] = InXSqlVars,
    description(T, [{H#column.name, H#column.type, H#column.scale,
                      H#column.length, H#column.null_ind} | XSqlVar]).

%% Commit and rollback
commit(TcpMod, Sock, TransHandle) ->
    TcpMod:send(Sock, efirebirdsql_op:op_commit_retaining(TransHandle)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response,  {ok, _, _}} -> ok;
        {op_response, {error, Msg}} -> {error, Msg}
    end.

rollback(TcpMod, Sock, TransHandle) ->
    TcpMod:send(Sock, efirebirdsql_op:op_rollback_retaining(TransHandle)),
    case efirebirdsql_op:get_response(TcpMod, Sock) of
        {op_response,  {ok, _, _}} -> ok;
        {op_response, {error, Msg}} -> {error, Msg}
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% -- client interface --
-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link(?MODULE, [], []).

get_parameter(C, Name) when is_list(Name) ->
    gen_server:call(C, {get_parameter, list_to_binary(Name)}, infinity);
get_parameter(C, Name) when is_list(Name) ->
    gen_server:call(C, {get_parameter, Name}, infinity).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% -- gen_server implementation --

init([]) ->
    {ok, #state{mod=gen_tcp}}.

handle_call({connect, Host, Username, Password, Database, Options}, _From, State) ->
    SockOptions = [{active, false}, {packet, raw}, binary],
    Port = proplists:get_value(port, Options, 3050),
    IsCreateDB = proplists:get_value(createdb, Options, false),
    PageSize = proplists:get_value(pagesize, Options, 4096),
    {Pub ,Private} = efirebirdsql_srp:client_seed(),
    case gen_tcp:connect(Host, Port, SockOptions) of
        {ok, Sock} ->
            State2 = State#state{
                sock=Sock,
                public_key=Pub,
                private_key=Private,
                wire_crypt=proplists:get_value(wire_crypt, Options, false)
            },
            {R, NewState} = connect(gen_tcp, Host, Username, Password, Database, IsCreateDB, PageSize, State2),
            {reply, R, NewState};
        Error = {error, _} ->
            {reply, Error, State}
    end;
handle_call({transaction, Options}, _From, State) ->
    AutoCommit = proplists:get_value(auto_commit, Options, true),
    %% isc_tpb_version3,isc_tpb_write,isc_tpb_wait,isc_tpb_read_committed,isc_tpb_no_rec_version
    Tpb = [3, 9, 6, 15, 18],
    R = begin_transaction(State#state.mod,
        State#state.sock, State#state.db_handle,
        lists:flatten(Tpb, if AutoCommit =:= true -> [16]; true -> [] end)),
    case R of
        {ok, TransHandle} ->
            {reply, ok, State#state{trans_handle=TransHandle}};
        {error, _Reason} ->
            {reply, R, State}
    end;
handle_call(commit, _From, State) ->
    {reply, commit(State#state.mod,
        State#state.sock, State#state.trans_handle), State};
handle_call(rollback, _From, State) ->
    {reply, rollback(State#state.mod,
        State#state.sock, State#state.trans_handle), State};
handle_call(detach, _From, State) ->
    {reply, detach(State#state.mod,
        State#state.sock, State#state.db_handle), State};
handle_call({prepare, Sql}, _From, State) ->
    case R = prepare_statement(State#state.mod, State#state.sock,
                State#state.trans_handle, State#state.stmt_handle, Sql) of
        {ok, StmtType, XSqlVars} ->
            {reply, ok, State#state{stmt_type=StmtType, xsqlvars=XSqlVars}};
        {error, _Reason} ->
            {reply, R, State}
    end;
handle_call({execute, Params}, _From, State) ->
    case State#state.stmt_type of
        isc_info_sql_stmt_exec_procedure ->
            {ok, Row} = execute2(State#state.mod, State#state.sock,
                State#state.trans_handle, State#state.stmt_handle, Params,
                State#state.xsqlvars),
            {reply, ok, State#state{rows=[Row]}};
        _ ->
            ok = execute(State#state.mod, State#state.sock,
                State#state.trans_handle, State#state.stmt_handle, Params),
            case State#state.stmt_type of
                isc_info_sql_stmt_select ->
                    {ok, Rows} = fetchrows(State#state.mod, State#state.sock,
                        State#state.stmt_handle, State#state.xsqlvars),
                    free_statement(
                        State#state.mod, State#state.sock, State#state.stmt_handle),
                    {reply, ok, State#state{rows=Rows}};
                _ ->
                    {reply, ok, State}
            end
    end;
handle_call(fetchone, _From, State) ->
    [R | Rest] = State#state.rows,
    ConvertedRow = efirebirdsql_op:convert_row(
        State#state.mod, State#state.sock,
        State#state.trans_handle, State#state.xsqlvars, R
    ),
    {reply, {ok, ConvertedRow}, State#state{rows=Rest}};
handle_call(fetchall, _From, State) ->
    ConvertedRows = [efirebirdsql_op:convert_row(
        State#state.mod, State#state.sock,
        State#state.trans_handle, State#state.xsqlvars, R
    ) || R <- State#state.rows],
    {reply, {ok, ConvertedRows}, State};
handle_call(description, _From, State) ->
    case State#state.stmt_type of
        isc_info_sql_stmt_select
            -> {reply, description(State#state.xsqlvars, []), State};
        _
            -> {reply, no_result, State}
    end;
handle_call({get_parameter, Name}, _From, State) ->
    Value1 = case lists:keysearch(Name, 1, State#state.parameters) of
        {value, {Name, Value}} -> Value;
        false                  -> undefined
    end,
    {reply, {ok, Value1}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({inet_reply, _, ok}, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
