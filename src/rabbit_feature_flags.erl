%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2018 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_feature_flags).

-export([list/0,
         list/1,
         list/2,
         enable/1,
         disable/1,
         is_supported/1,
         is_supported_locally/1,
         is_supported_remotely/1,
         is_supported_remotely/2,
         are_supported/1,
         are_supported_locally/1,
         are_supported_remotely/1,
         are_supported_remotely/2,
         is_enabled/1,
         info/0,

         init/0,
         check_node_compatibility/1,
         check_node_compatibility/2,
         is_node_compatible/1,
         is_node_compatible/2,
         sync_feature_flags_with_cluster/1,
         sync_feature_flags_with_cluster/2
        ]).

%% Internal use only.
-export([initialize_registry/0,
         mark_as_enabled_locally/1]).

%% Default timeout for operations on remote nodes.
-define(TIMEOUT, 60000).

list() -> list(all).

list(all)      -> rabbit_ff_registry:list(all);
list(enabled)  -> rabbit_ff_registry:list(enabled);
list(disabled) -> maps:filter(
                    fun(FeatureName, _) -> not is_enabled(FeatureName) end,
                    list(all)).

list(Which, Stability)
  when Stability =:= stable orelse Stability =:= experimental ->
    maps:filter(fun(_, FeatureProps) ->
                        case maps:get(stability, FeatureProps, stable) of
                            Stability -> true;
                            _         -> false
                        end
                end, list(Which)).

enable(FeatureName) ->
    rabbit_log:info("Feature flag `~s`: REQUEST TO ENABLE",
                    [FeatureName]),
    case is_enabled(FeatureName) of
        true ->
            rabbit_log:info("Feature flag `~s`: already enabled",
                            [FeatureName]),
            ok;
        false ->
            rabbit_log:info("Feature flag `~s`: not enabled, "
                            "check if supported by cluster",
                            [FeatureName]),
            %% The feature flag must be supported locally and remotely
            %% (i.e. by all members of the cluster).
            case is_supported(FeatureName) of
                true ->
                    rabbit_log:info("Feature flag `~s`: supported, "
                                    "attempt to enable...",
                                    [FeatureName]),
                    do_enable(FeatureName);
                false ->
                    rabbit_log:info("Feature flag `~s`: not supported",
                                    [FeatureName]),
                    {error, unsupported}
            end
    end.

enable_locally(FeatureName) ->
    case is_enabled(FeatureName) of
        true ->
            ok;
        false ->
            rabbit_log:info(
              "Feature flag `~s`: enable locally (i.e. was enabled on the cluster "
              "when this node was not part of it)",
              [FeatureName]),
            do_enable_locally(FeatureName)
    end.

disable(_FeatureName) ->
    {error, unsupported}.

is_supported(FeatureName) when is_atom(FeatureName) ->
    is_supported_locally(FeatureName) andalso
    is_supported_remotely(FeatureName).

is_supported_locally(FeatureName) when is_atom(FeatureName) ->
    rabbit_ff_registry:is_supported(FeatureName).

is_supported_remotely(FeatureName) ->
    is_supported_remotely(FeatureName, ?TIMEOUT).

is_supported_remotely(FeatureName, Timeout) ->
    are_supported_remotely([FeatureName], Timeout).

are_supported(FeatureNames) when is_list(FeatureNames) ->
    are_supported_locally(FeatureNames) andalso
    are_supported_remotely(FeatureNames).

are_supported_locally(FeatureNames) when is_list(FeatureNames) ->
    lists:all(fun(F) -> is_supported_locally(F) end, FeatureNames).

are_supported_remotely(FeatureNames) when is_list(FeatureNames) ->
    are_supported_remotely(FeatureNames, ?TIMEOUT).

are_supported_remotely([], _) ->
    rabbit_log:info("Feature flags: skipping query for feature flags "
                    "support as the given list is empty",
                    []),
    true;
are_supported_remotely(FeatureNames, Timeout) when is_list(FeatureNames) ->
    case running_remote_nodes() of
        [] ->
            rabbit_log:info("Feature flags: isolated node; "
                            "skipping remote node query "
                            "=> consider `~p` supported",
                            [FeatureNames]),
            true;
        RemoteNodes ->
            rabbit_log:info("Feature flags: about to query these remote nodes "
                            "about support for `~p`: ~p",
                            [FeatureNames, RemoteNodes]),
            are_supported_remotely(RemoteNodes, FeatureNames, Timeout)
    end.

are_supported_remotely(_, [], _) ->
    rabbit_log:info("Feature flags: skipping query for feature flags "
                    "support as the given list is empty",
                    []),
    true;
are_supported_remotely([Node | Rest], FeatureNames, Timeout) ->
    case does_node_support(Node, FeatureNames, Timeout) of
        true ->
            are_supported_remotely(Rest, FeatureNames, Timeout);
        false ->
            rabbit_log:error("Feature flags: stopping query "
                             "for support for `~p` here",
                             [FeatureNames]),
            false
    end;
are_supported_remotely([], FeatureNames, _) ->
    rabbit_log:info("Feature flags: all running remote nodes support `~p`",
                    [FeatureNames]),
    true.

is_enabled(FeatureName) when is_atom(FeatureName) ->
    rabbit_ff_registry:is_enabled(FeatureName).

info() ->
    rabbit_feature_flags_extra:info().

%% -------------------------------------------------------------------
%% Feature flags registry.
%% -------------------------------------------------------------------

init() ->
    _ = list(all),
    ok.

initialize_registry() ->
    rabbit_log:info("Feature flags: (re)initialize registry", []),
    AllFeatureFlags = query_supported_feature_flags(),
    EnabledFeatureNames = read_enabled_feature_flags_list(),
    EnabledFeatureFlags = maps:filter(
                            fun(FeatureName, _) ->
                                    lists:member(FeatureName,
                                                 EnabledFeatureNames)
                            end, AllFeatureFlags),
    rabbit_log:info("Feature flags: List of feature flags found:", []),
    lists:foreach(
      fun(FeatureName) ->
              rabbit_log:info(
                "Feature flags:   [~s] ~s",
                [case maps:is_key(FeatureName, EnabledFeatureFlags) of
                     true  -> "x";
                     false -> " "
                 end,
                 FeatureName])
      end, lists:sort(maps:keys(AllFeatureFlags))),
    regen_registry_mod(AllFeatureFlags, EnabledFeatureFlags).

query_supported_feature_flags() ->
    rabbit_log:info("Feature flags: query feature flags "
                    "in loaded applications", []),
    AttributesPerApp = rabbit_misc:all_module_attributes(rabbit_feature_flag),
    query_supported_feature_flags(AttributesPerApp, #{}).

query_supported_feature_flags([{App, _Module, Attributes} | Rest],
                              AllFeatureFlags) ->
    rabbit_log:info("Feature flags: application `~s` "
                    "has ~b feature flags",
                    [App, length(Attributes)]),
    AllFeatureFlags1 = lists:foldl(
                         fun({FeatureName, FeatureProps}, AllFF) ->
                                 merge_new_feature_flags(AllFF,
                                                         App,
                                                         FeatureName,
                                                         FeatureProps)
                         end, AllFeatureFlags, Attributes),
    query_supported_feature_flags(Rest, AllFeatureFlags1);
query_supported_feature_flags([], AllFeatureFlags) ->
    AllFeatureFlags.

merge_new_feature_flags(AllFeatureFlags, App, FeatureName, FeatureProps)
  when is_atom(FeatureName) andalso is_map(FeatureProps) ->
    FeatureProps1 = maps:put(provided_by, App, FeatureProps),
    maps:merge(AllFeatureFlags,
               #{FeatureName => FeatureProps1}).

regen_registry_mod(AllFeatureFlags, EnabledFeatureFlags) ->
    %% -module(rabbit_ff_registry).
    ModuleAttr = erl_syntax:attribute(
                   erl_syntax:atom(module),
                   [erl_syntax:atom(rabbit_ff_registry)]),
    ModuleForm = erl_syntax:revert(ModuleAttr),
    %% -export([...]).
    ExportAttr = erl_syntax:attribute(
                   erl_syntax:atom(export),
                   [erl_syntax:list(
                      [erl_syntax:arity_qualifier(
                         erl_syntax:atom(F),
                         erl_syntax:integer(A))
                       || {F, A} <- [{list, 1},
                                     {is_supported, 1},
                                     {is_enabled, 1}]]
                     )
                   ]
                  ),
    ExportForm = erl_syntax:revert(ExportAttr),
    %% list(_) -> ...
    ListAllBody = erl_syntax:abstract(AllFeatureFlags),
    ListAllClause = erl_syntax:clause([erl_syntax:atom(all)],
                                      [],
                                      [ListAllBody]),
    ListEnabledBody = erl_syntax:abstract(EnabledFeatureFlags),
    ListEnabledClause = erl_syntax:clause([erl_syntax:atom(enabled)],
                                          [],
                                          [ListEnabledBody]),
    ListFun = erl_syntax:function(
                erl_syntax:atom(list),
                [ListAllClause, ListEnabledClause]),
    ListFunForm = erl_syntax:revert(ListFun),
    %% is_supported(_) -> ...
    IsSupportedClauses = [
                          erl_syntax:clause(
                            [erl_syntax:atom(FeatureName)],
                            [],
                            [erl_syntax:atom(true)])
                          || FeatureName <- maps:keys(AllFeatureFlags)
                         ],
    NotSupportedClause = erl_syntax:clause(
                           [erl_syntax:variable("_")],
                           [],
                           [erl_syntax:atom(false)]),
    IsSupportedFun = erl_syntax:function(
                       erl_syntax:atom(is_supported),
                       IsSupportedClauses ++ [NotSupportedClause]),
    IsSupportedFunForm = erl_syntax:revert(IsSupportedFun),
    %% is_enabled(_) -> ...
    IsEnabledClauses = [
                        erl_syntax:clause(
                          [erl_syntax:atom(FeatureName)],
                          [],
                          [erl_syntax:atom(
                             maps:is_key(FeatureName, EnabledFeatureFlags))])
                        || FeatureName <- maps:keys(AllFeatureFlags)
                       ],
    NotEnabledClause = erl_syntax:clause(
                         [erl_syntax:variable("_")],
                         [],
                         [erl_syntax:atom(false)]),
    IsEnabledFun = erl_syntax:function(
                     erl_syntax:atom(is_enabled),
                     IsEnabledClauses ++ [NotEnabledClause]),
    IsEnabledFunForm = erl_syntax:revert(IsEnabledFun),
    %% Compilation!
    Forms = [ModuleForm,
             ExportForm,
             ListFunForm,
             IsSupportedFunForm,
             IsEnabledFunForm],
    CompileOpts = [return_errors,
                   return_warnings],
    case compile:forms(Forms, CompileOpts) of
        {ok, Mod, Bin, _} ->
            load_registry_mod(Mod, Bin);
        {error, Errors, Warnings} ->
            rabbit_log:error("Feature flags: registry compilation:~n"
                             "Errors: ~p~n"
                             "Warnings: ~p",
                             [Errors, Warnings]),
            {error, compilation_failure}
    end.

load_registry_mod(Mod, Bin) ->
    rabbit_log:info("Feature flags: registry module ready, loading it..."),
    LockId = {?MODULE, self()},
    FakeFilename = "Compiled and loaded by " ++ ?MODULE_STRING,
    global:set_lock(LockId, [node()]),
    _ = code:soft_purge(Mod),
    _ = code:delete(Mod),
    Ret = code:load_binary(Mod, FakeFilename, Bin),
    global:del_lock(LockId, [node()]),
    case Ret of
        {module, _} ->
            rabbit_log:info("Feature flags: registry module loaded"),
            ok;
        {error, Reason} ->
            rabbit_log:info("Feature flags: failed to load registry "
                            "module: ~p",
                            [Reason]),
            throw({feature_flag_registry_reload_failure, Reason})
    end.

%% -------------------------------------------------------------------
%% Feature flags state storage.
%% -------------------------------------------------------------------

read_enabled_feature_flags_list() ->
    File = enabled_feature_flags_list_file(),
    case file:consult(File) of
        {ok, [List]}    -> List;
        {error, enoent} -> [];
        {error, Reason} -> {error, Reason}
    end.

write_enabled_feature_flags_list(FeatureNames) ->
    File = enabled_feature_flags_list_file(),
    Content = io_lib:format("~p.~n", [FeatureNames]),
    file:write_file(File, Content).

enabled_feature_flags_list_file() ->
    %% FIXME: Use a feature-flags-specific directory.
    filename:join(rabbit_mnesia:dir(), "feature_flags").

%% -------------------------------------------------------------------
%% Feature flags management: enabling.
%% -------------------------------------------------------------------

do_enable(FeatureName) ->
    case enable_dependencies(FeatureName, true) of
        ok ->
            case run_migration_fun(FeatureName, enable) of
                ok    -> mark_as_enabled(FeatureName);
                Error -> Error
            end;
        Error -> Error
    end.

do_enable_locally(FeatureName) ->
    case enable_dependencies(FeatureName, false) of
        ok ->
            case run_migration_fun(FeatureName, enable) of
                ok    -> mark_as_enabled_locally(FeatureName);
                Error -> Error
            end;
        Error -> Error
    end.

enable_dependencies(FeatureName, Everywhere) ->
    #{FeatureName := FeatureProps} = rabbit_ff_registry:list(all),
    DependsOn = maps:get(depends_on, FeatureProps, []),
    rabbit_log:info("Feature flag `~s`: enable dependencies: ~p",
                    [FeatureName, DependsOn]),
    enable_dependencies(FeatureName, DependsOn, Everywhere).

enable_dependencies(TopLevelFeatureName, [FeatureName | Rest], Everywhere) ->
    Ret = case Everywhere of
              true  -> enable(FeatureName);
              false -> enable_locally(FeatureName)
          end,
    case Ret of
        ok    -> enable_dependencies(TopLevelFeatureName, Rest, Everywhere);
        Error -> Error
    end;
enable_dependencies(_, [], _) ->
    ok.

run_migration_fun(FeatureName, Arg) ->
    #{FeatureName := FeatureProps} = rabbit_ff_registry:list(all),
    case maps:get(migration_fun, FeatureProps, none) of
        {MigrationMod, MigrationFun}
          when is_atom(MigrationMod) andalso is_atom(MigrationFun) ->
            rabbit_log:info("Feature flag `~s`: run migration function ~p "
                            "with arg: ~p",
                            [FeatureName, MigrationFun, Arg]),
            try
                erlang:apply(MigrationMod, MigrationFun, [Arg])
            catch
                _:Reason:Stacktrace ->
                    rabbit_log:error("Feature flag `~s`: migration function "
                                     "crashed: ~p~n~p",
                                     [FeatureName, Reason, Stacktrace]),
                    {error, {migration_fun_crash, Reason, Stacktrace}}
            end;
        none ->
            ok;
        Invalid ->
            rabbit_log:error("Feature flag `~s`: invalid migration "
                             "function: ~p",
                            [FeatureName, Invalid]),
            {error, {invalid_migration_fun, Invalid}}
    end.

mark_as_enabled(FeatureName) ->
    ok = mark_as_enabled_locally(FeatureName),
    ok = mark_as_enabled_remotely(FeatureName).

mark_as_enabled_locally(FeatureName) ->
    rabbit_log:info("Feature flag `~s`: mark as enabled",
                    [FeatureName]),
    EnabledFeatureNames = read_enabled_feature_flags_list(),
    EnabledFeatureNames1 = [FeatureName | EnabledFeatureNames],
    write_enabled_feature_flags_list(EnabledFeatureNames1),
    initialize_registry().

mark_as_enabled_remotely(FeatureName) ->
    %% FIXME: Handle error cases.
    [ok = rpc:call(Node, ?MODULE, mark_as_enabled_locally, [FeatureName], ?TIMEOUT)
     || Node <- running_remote_nodes()],
    ok.

%% -------------------------------------------------------------------
%% Coordination with remote nodes.
%% -------------------------------------------------------------------

running_remote_nodes() ->
    mnesia:system_info(running_db_nodes).

does_node_support(Node, FeatureNames, Timeout) ->
    rabbit_log:info("Feature flags: querying `~p` support on node ~s...",
                    [FeatureNames, Node]),
    Ret = case node() of
              Node ->
                  are_supported_locally(FeatureNames);
              _ ->
                  rpc:call(Node,
                           ?MODULE, are_supported_locally, [FeatureNames],
                           Timeout)
          end,
    case Ret of
        {badrpc, {'EXIT',
                  {undef,
                   [{?MODULE, are_supported_locally, [FeatureNames], []}
                    | _]}}} ->
            rabbit_log:info(
              "Feature flags: ?MODULE:are_supported_locally(~p) unavailable on node `~s`: "
              "assuming it is a RabbitMQ 3.7.x node "
              "=> consider the feature flags unsupported",
              [FeatureNames, Node]),
            false;
        {badrpc, Reason} ->
            rabbit_log:error("Feature flags: error while querying `~p` "
                             "support on node ~s: ~p",
                             [FeatureNames, Node, Reason]),
            false;
        true ->
            rabbit_log:info("Feature flags: node `~s` supports `~p`",
                            [Node, FeatureNames]),
            true;
        false ->
            rabbit_log:info("Feature flags: node `~s` does not support `~p`; "
                            "stopping query here",
                            [Node, FeatureNames]),
            false
    end.

check_node_compatibility(Node) ->
    check_node_compatibility(Node, ?TIMEOUT).

check_node_compatibility(Node, Timeout) ->
    rabbit_log:info("Feature flags: determining if node `~s` is compatible",
                    [Node]),
    rabbit_log:info("Feature flags: node `~s` compatibility check, part 1/2",
                    [Node]),
    Part1 = local_enabled_feature_flags_are_supported_remotely(Node, Timeout),
    rabbit_log:info("Feature flags: node `~s` compatibility check, part 2/2",
                    [Node]),
    Part2 = remote_enabled_feature_flags_are_supported_locally(Node, Timeout),
    case {Part1, Part2} of
        {true, true} ->
            rabbit_log:info("Feature flags: node `~s` is compatible", [Node]),
            ok;
        {false, _} ->
            rabbit_log:info("Feature flags: node `~s` is INCOMPATIBLE: "
                            "feature flags enabled locally are not "
                            "supported remotely",
                            [Node]),
            {error, incompatible_feature_flags};
        {_, false} ->
            rabbit_log:info("Feature flags: node `~s` is INCOMPATIBLE: "
                            "feature flags enabled remotely are not "
                            "supported locally",
                            [Node]),
            {error, incompatible_feature_flags}
    end.

is_node_compatible(Node) ->
    is_node_compatible(Node, ?TIMEOUT).

is_node_compatible(Node, Timeout) ->
    check_node_compatibility(Node, Timeout) =:= ok.

local_enabled_feature_flags_are_supported_remotely(Node, Timeout) ->
    LocalEnabledFeatureNames = maps:keys(list(enabled)),
    are_supported_remotely([Node], LocalEnabledFeatureNames, Timeout).

remote_enabled_feature_flags_are_supported_locally(Node, Timeout) ->
    case query_remote_feature_flags(Node, enabled, Timeout) of
        {error, _} ->
            false;
        RemoteEnabledFeatureFlags when is_map(RemoteEnabledFeatureFlags) ->
            RemoteEnabledFeatureNames = maps:keys(RemoteEnabledFeatureFlags),
            are_supported_locally(RemoteEnabledFeatureNames)
    end.

query_remote_feature_flags(Node, Which, Timeout) ->
    rabbit_log:info("Feature flags: querying ~s feature flags "
                    "on node `~s`...",
                    [Which, Node]),
    case rpc:call(Node, ?MODULE, list, [Which], Timeout) of
        {badrpc, {'EXIT',
                  {undef,
                   [{?MODULE, list, [Which], []}
                    | _]}}} ->
            rabbit_log:info(
              "Feature flags: ?MODULE:list(~s) unavailable on node `~s`: "
              "assuming it is a RabbitMQ 3.7.x node "
              "=> consider the list empty",
              [Which, Node]),
            #{};
        {badrpc, Reason} = Error ->
            rabbit_log:error(
              "Feature flags: error while querying ~s feature flags "
              "on node `~s`: ~p",
              [Which, Node, Reason]),
            {error, Error};
        RemoteFeatureFlags when is_map(RemoteFeatureFlags) ->
            RemoteFeatureNames = maps:keys(RemoteFeatureFlags),
            rabbit_log:info("Feature flags: querying ~s feature flags "
                            "on node `~s` done; ~s features: ~p",
                            [Which, Node, Which, RemoteFeatureNames]),
            RemoteFeatureFlags
    end.

sync_feature_flags_with_cluster(Nodes) ->
    sync_feature_flags_with_cluster(Nodes, ?TIMEOUT).

sync_feature_flags_with_cluster([], _) ->
    ok;
sync_feature_flags_with_cluster(Nodes, Timeout) ->
    RemoteNodes = Nodes -- [node()],
    sync_feature_flags_with_cluster1(RemoteNodes, Timeout).

sync_feature_flags_with_cluster1([], _) ->
    ok;
sync_feature_flags_with_cluster1(RemoteNodes, Timeout) ->
    RandomRemoteNode = pick_one_node(RemoteNodes),
    rabbit_log:info("Feature flags: SYNCING FEATURE FLAGS with node `~s`...",
                    [RandomRemoteNode]),
    case query_remote_feature_flags(RandomRemoteNode, enabled, Timeout) of
        {error, _} = Error ->
            Error;
        RemoteFeatureFlags ->
            RemoteFeatureNames = maps:keys(RemoteFeatureFlags),
            do_sync_feature_flags_with_node1(RemoteFeatureNames)
    end.

pick_one_node(Nodes) ->
    RandomIndex = rand:uniform(length(Nodes)),
    lists:nth(RandomIndex, Nodes).

do_sync_feature_flags_with_node1([FeatureFlag | Rest]) ->
    case enable_locally(FeatureFlag) of
        ok    -> do_sync_feature_flags_with_node1(Rest);
        Error -> Error
    end;
do_sync_feature_flags_with_node1([]) ->
    ok.