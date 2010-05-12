-module(qilr_analyzer_monitor).

-behaviour(gen_server).

-include("analysis_pb.hrl").

%% API
-export([start_link/0, stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {port,
                sock,
                portnum}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

stop() ->
    gen_server:cast(?SERVER, stop_analyzer).

init([]) ->
    process_flag(trap_exit, true),
    {ok, PortNum} = application:get_env(analysis_port),
    case application:get_env(analysis_port) of
        {ok, PortNum} when is_integer(PortNum) ->
            CmdDir = filename:join([priv_dir(), "analysis_server"]),
            Cmd = filename:join([CmdDir, "analysis_server.sh"]),
            case catch erlang:open_port({spawn_executable, Cmd}, [stderr_to_stdout,
                                                                  {args, [integer_to_list(PortNum)]},
                                                                  {cd, CmdDir}]) of
                {'EXIT', Error} ->
                    {stop, Error};
                Port when is_port(Port) ->
                    case connect({127,0,0,1}, PortNum, [{active, false},
                                                        binary, {packet, 4}], 10) of
                        {ok, Sock} ->
                            erlang:link(Port),
                            erlang:link(Sock),
                            {ok, #state{port=Port, portnum=PortNum, sock=Sock}};
                        _ ->
                            {stop, connect_error}
                    end
            end;
        _ ->
            {stop, {error, missing_port}}
    end.

handle_call(_Request, _From, State) ->
    {reply, ignore, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Sock, _}, #state{portnum=PortNum, sock=Sock}=State) ->
    error_logger:info_msg("Re-establishing connection"),
    gen_tcp:close(Sock),
    {ok, NewSock} = gen_tcp:connect({127,0,0,1}, PortNum, [{active, false}, binary, {packet, 4}]),
    {noreply, State#state{sock=NewSock}};

handle_info({_Port, _Message}, State) ->
    {stop, java_error, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{sock=Sock}) ->
    StopCmd = #analysisrequest{text= <<"__basho_analyzer_monitor_stop__">>},
    gen_tcp:send(Sock, analysis_pb:encode_analysisrequest(StopCmd)),
    io:format("Sent terminate~n"),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private functions
connect(_Addr, _PortNum, _Options, 0) ->
    {error, no_connection};
connect(Addr, PortNum, Options, Tries) ->
    case gen_tcp:connect(Addr, PortNum, Options) of
        {ok, Sock} ->
            {ok, Sock};
        _ ->
            timer:sleep(250),
            connect(Addr, PortNum, Options, Tries - 1)
    end.

priv_dir() ->
    case code:priv_dir(qilr) of
        {error, bad_name} ->
            Path0 = filename:dirname(code:which(?MODULE)),
            Path1 = filename:absname_join(Path0, ".."),
            filename:join([Path1, "priv"]);
        Path ->
            filename:absname(Path)
    end.
