%% License: Apache License, Version 2.0
%%
%% Copyright 2014 Huaban.com
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% @author Tienson Qin <tiensonqin@gmail.com>
%% @copyright Copyright 2014 Huaban.com 
%%
%% @doc Riemann client for sending events and states to a riemann server
%%
%% @end

%%%=========================================================================
%%%  TODO
%%%=========================================================================
%% 1. Difference TCP and UDP, smaller messages flow to UDP
%% 2. Attribute support
%% 3. property-based quickcheck

-module(hobbit).

-behaviour(gen_server).
-compile(export_all).
%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% API
-export([
         start/0,
         start_link/0,
         stop/0,
         send/1,
         query/1]).

-include("riemann_pb.hrl").

-record(state, {
    tcp_socket,
    udp_socket
}).

%% riemann state attributes set
-define(SAS, record_info(fields, riemannstate)).

%% riemann event attributes set
-define(EAS, record_info(fields, riemannevent)).

%% unique attributes set
-define(UAS, [tags,attributes]).

-type send_response() :: ok | {error, _Reason}.
-type query_response() :: {ok, [#riemannevent{}]} | {error, _Reason}.

-type r_query() :: string().

-type r_time() :: {time, non_neg_integer()}.
-type r_state() :: {state, string()}.
-type r_service_name() :: string().
-type r_service() :: {service, r_service_name()}.
-type r_host() :: {host, string()}.
-type r_description() :: {description, string()}.
-type r_tags() :: {tags, [string()]}.
-type r_ttl() :: {ttl, float()}.

-type event_metric() :: {metric, number()}.
-type event_attributes() :: {attributes, [{string(), string()}]}.
-type event_opts() :: 
    event_metric()
  | event_attributes()
  | r_state() 
  | r_service() 
  | r_host() 
  | r_description() 
  | r_tags() 
  | r_ttl() 
  | r_time().

-type state_once() :: {once, boolean()}.
-type state_opts() ::
    state_once()
  | r_state() 
  | r_service() 
  | r_host() 
  | r_description() 
  | r_tags() 
  | r_ttl() 
      | r_time().

%%%=========================================================================
%%%  API
%%%=========================================================================

start() ->
  application:start(?MODULE).

start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
  gen_server:cast(?MODULE, stop).


%% -------------------------------------------------------------------------
%% @doc Send event or state to riemann
%% -------------------------------------------------------------------------
-spec send([event_opts()]) -> send_response().
send(Entity) ->
  gen_server:call(?MODULE, {send, Entity}).

-spec send_state([state_opts()]) -> send_response().
send_state(Entity) ->
  gen_server:call(?MODULE, {send_state, Entity}).

%% -------------------------------------------------------------------------
%% @doc Query from riemann
%% -------------------------------------------------------------------------
-spec query(r_query()) -> query_response().
query(Query) ->
  gen_server:call(?MODULE, {query, Query}).

%%%=========================================================================
%%%  gen_server callbacks
%%%=========================================================================

init([]) ->
  %% Connect to riemann
  case riemann_setup() of
    {error, Reason} ->
      lager:error("Failed to connect to riemann with the reason ~p", [Reason]),
      {stop, Reason};
    {ok, State} -> {ok, State}
  end.

%% Event is a tuple with host, service, state, etc
handle_call({send, Entity}, _From, State) ->
  %% convert the entity to message and send it
  {Reply, S2} = case send_msg(convert(Entity, event), State) of
                     {{ok, _}, S1} -> {ok, S1};
                     Other -> Other
                   end,
  {reply, Reply, S2};

handle_call({send_state, Entity}, _From, State) ->
  %% convert the entity to message and send it
  {Reply, S2} = case send_msg(convert(Entity, state), State) of
                     {{ok, _}, S1} -> {ok, S1};
                     Other -> Other
                   end,
  {reply, Reply, S2};

handle_call({query, Query}, _From, State) ->
  Msg = #riemannmsg{
           pb_query = #riemannquery{
                         string = atom_to_list(Query)
                        }
          },
  {Reply, S2} = case send_msg(Msg, State) of
                     {{ok, #riemannmsg{events=Events}}, S1} -> {{ok, Events}, S1};
                     Other -> Other
                   end,
  {reply, Reply, S2}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, #state{udp_socket=UdpSocket, tcp_socket=TcpSocket}) ->
  %% gen_udp:close(UdpSocket),
  gen_tcp:close(TcpSocket),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
  
%%%=========================================================================
%%%  Internal functions
%%%=========================================================================

riemann_setup() ->
  Host = get_env(host, "127.0.0.1"),
  Port = get_env(port, 5555),
  Options = [binary, {active,false}, {keepalive, true}, {nodelay, true}],
  Timeout = 10000,
  tcp_setup(Host, Port, Options, Timeout).

tcp_setup(Host, Port, Options, Timeout) ->
  case gen_tcp:connect(Host, Port, Options, Timeout) of
    {ok, TcpSocket} ->
      ok = gen_tcp:controlling_process(TcpSocket, self()),
      {ok, #state{tcp_socket = TcpSocket}};
    {error, Reason} ->
      {error, Reason}
  end.

convert(Entity, Kind) ->
  {Type, NewEntity} = complement(Entity, Kind),
  case Type of
    state ->
      NewEntity1 = rm_list_to_tuple(NewEntity, riemannstate),
      #riemannmsg{states = [NewEntity1]};
    event ->
      NewEntity1 = rm_list_to_tuple(NewEntity, riemannevent),
      Entity2 = add_metric_value(NewEntity, NewEntity1),
      #riemannmsg{events = [Entity2]}
  end.

rm_list_to_tuple(Entity, RecordType) ->
  List = case RecordType of
           riemannstate -> ?SAS;
           riemannevent -> ?EAS
         end,
  list_to_tuple([RecordType|[proplists:get_value(X, Entity)
                               || X <- List]]).

complement(Entity, Kind) ->
  %% complement by its type
  DefaultEntity = case Kind of
                    %% state type
                    state  ->
                      default_entity(state);
                    %% event type
                    event ->
                      default_entity(event)
                  end,
  NewEntity = orddict:merge(fun(_K,V1,_V2)->V1 end, Entity, DefaultEntity),
  E1 = lists:map(fun({K,V})->value(K,V) end, NewEntity),
  {Kind, E1}.

default_entity(state) ->
  lists:map(fun default_attr/1, ?SAS);
default_entity(event) ->
  lists:map(fun default_attr/1, ?EAS).

default_attr(V) ->
  case lists:member(V, ?UAS) of
    true -> {V, []};
    false -> {V, undefined}
  end.

value(K,V) when is_number(V) ->
  {K,V};
%% value(K,V) when is_list(V) ->
%%   {K,[val(NV) || NV <- V]};
value(K,V) when K == host, V == undefined ->
  value(K, node());
value(K,V) when V == undefined ->
  {K, V};
value(K,V) when is_atom(V) ->
  {K,atom_to_list(V)};
value(K,V) ->
  {K, V}.

val(V) when is_number(V) ->
  V;
val(V) when is_atom(V)->
  atom_to_list(V);
val(V) when is_list(V) ->
  V.

send_msg(Msg, State) ->
  BinMsg = iolist_to_binary(riemann_pb:encode_riemannmsg(Msg)),
  MessageSize = byte_size(BinMsg),
  MsgWithLength = <<MessageSize:32/integer-big, BinMsg/binary>>,
  transfer(MsgWithLength, State).

transfer(Msg, #state{tcp_socket=Socket}=State) ->
  case gen_tcp:send(Socket, Msg) of
    ok ->
      {await_reply(Socket), State};
    {error, Reason} ->
      lager:error("Failed sending event to riemann with reason: ~p", [Reason]),
      {{error, Reason}, State}
  end.

await_reply(TcpSocket) ->
  case gen_tcp:recv(TcpSocket, 0, 3000) of
    {ok, BinResp} ->
      case decode_response(BinResp) of
        #riemannmsg{ok=true} = Msg -> {ok, Msg};
        #riemannmsg{ok=false, error=Reason} -> {error, Reason}
      end;
    Other -> Other
  end.

decode_response(<<MsgLength:32/integer-big, Data/binary>>) ->
  case Data of
    <<Msg:MsgLength/binary, _/binary>> ->
      riemann_pb:decode_riemannmsg(Msg);
    _ ->
      lager:error("Failed at decoding response from riemann"),
      #riemannmsg{
         ok = false,
         error = "Decoding response from Riemann failed"
        }
  end.

add_metric_value(Vals, Event) ->
  case proplists:get_value(metric, Vals, 0) of
    V when is_integer(V) ->
      Event#riemannevent{metric_f = V * 1.0, metric_sint64 = V};
    V ->
      Event#riemannevent{metric_f = V, metric_d = V}
  end.
  
get_env(Key, Default) ->
  case application:get_env(riemann, Key) of
    {ok, V} -> V;
    undefined -> Default
  end.
