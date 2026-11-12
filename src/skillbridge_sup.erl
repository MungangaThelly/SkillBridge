-module(skillbridge_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Port = case os:getenv("SKILLBRIDGE_PORT") of
        false -> application:get_env(skillbridge, port, 8080);
        Value -> try list_to_integer(Value) catch _:_ -> application:get_env(skillbridge, port, 8080) end
    end,
    Children = [#{id => skillbridge_store, start => {skillbridge_store, start_link, []},
                  restart => permanent, shutdown => 5000, type => worker, modules => [skillbridge_store]},
                #{id => skillbridge_http, start => {skillbridge_http, start_link, [Port]},
                  restart => permanent, shutdown => 5000, type => worker, modules => [skillbridge_http]}],
    {ok, {#{strategy => one_for_one, intensity => 3, period => 10}, Children}}.
