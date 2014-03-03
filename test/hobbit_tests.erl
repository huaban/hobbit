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
%% @doc Riemann client test
%%
%% @end
-module(hobbit_tests).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

hobbit_test_() ->
  {
    %% "Ensure Eunit runs with tests in a \'test\' dir and no defined suite",
   setup,
   fun setup/0,  % setup
   fun api_test_/0}. % instantiator

setup() ->
  application:start(lager),
  application:start(hobbit).

api_test_() ->
  [send_event(),
   send_state(),
   query_matched(),
   query_not_matched()].

send_event() ->
setup(),
  Event = [
           {service, "redis"}, 
           {state, "ok"}, 
           {metric, 100}, 
           {tags, ["group1", "ssd"]}],

  ?_assertEqual(ok, hobbit:send(Event)).

send_state() ->
  State = [
           {service, redis}, 
           {state, critical},
           {description, drop}],
  ?_assertEqual(ok, hobbit:send_state(State)).

query_matched() ->
  Query = 'service ~= \"redis\"',
  ?_assertMatch({ok, [{riemannevent,_,"ok","redis",_,undefined,["group1","ssd"],_,[],_,undefined,_}]}, hobbit:query(Query)).

query_not_matched() ->
  Query = 'service ~= \"bingodjflksbgin\"',
  ?_assertMatch({ok, []}, hobbit:query(Query)).
