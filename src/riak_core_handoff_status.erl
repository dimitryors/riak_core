%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(riak_core_handoff_status).

-compile(export_all).
-include("riak_core_handoff.hrl").

print_handoff_summary() ->
    Status = transfer_summary(),
    Output = riak_core_console_writer:write(Status),
    io:format("~s", [Output]).

%% TODO (jwest): remember to take into account different vnode mods
transfer_summary() ->
    %% TODO (jwest): get ring from claimant?
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    {Summary, DownNodes} = build_transfer_summary(
                             ongoing_transfers_summary(), Ring),
                                        
    %% TODO (jwest): this is better in a macro
    %% TODO (mallen): suppress empty categories?
    Schema = ["Node", "Ownership", "Fallback", "Resize", "Repair"],
    Header = {text, "Key: Ongoing / Outstanding / Total"},
    Table = {table, Schema, 
        [ [ format_node_name(Node, DownNodes) | format_summary(S) ] 
                                || {Node, S} <- orddict:to_list(Summary) ]},
    [Header, Table].

rt(I) -> 
    binary_to_list(iolist_to_binary(I)).

format_summary(S) ->
    format_summary(S, default, " ~B / ~B / ~B ").

format_summary(Summary, Fields, OutputFormat) ->
    [ rt(format_summary1(orddict:fetch(T, Summary), Fields, OutputFormat)) || 
        T <- [ownership_transfer, hinted_handoff, resize_transfer, repair] ].

% The contents of Data 
% Quoting from riak_core_handoff_manager.erl #368
%  [{mod, Mod},
%   {src_partition, SrcP},
%   {target_partition, TargetP},
%   {src_node, SrcNode},
%   {target_node, TargetNode},
%   {direction, Dir},
%   {status, Status},
%   {start_ts, StartTS},
%   {sender_pid, TPid},
%   {stats, calc_stats(HO)}]

format_summary1({On, Out, Total, _Data}, default, OutputFormat) ->
    io_lib:format(OutputFormat, [On, Out, Total]).
    
-spec format_node_name(node(), [node()]) -> string().
format_node_name(Node, DownNodes) when is_atom(Node) ->
    case lists:member(Node, DownNodes) of
        true  -> 
            "**" ++ atom_to_list(Node) ++ "  ";
        false -> 
            "  " ++ atom_to_list(Node) ++ "  "
    end.

build_transfer_summary({OngoingSummary, DownNodes}, Ring) ->
    Outstanding = [ outstanding_count(T, Ring) 
                    || T <- [ownership_transfer, hinted_handoff, resize_transfer, repair] ],
    {orddict:map(
       fun(Node, D) -> merge_outstanding(Node, D, Outstanding) end, 
       OngoingSummary), DownNodes}.

merge_outstanding(Node, Ongoing, Outstanding) ->
    [O, H, Rz, Rp] = lists:map(
        fun(L) -> proplists:get_value(Node, L, 0) end, Outstanding),
    orddict:map(
      fun(K, V) -> 
        case K of
            ownership_transfer -> 
                build_summary_tuple(V, O);
                hinted_handoff -> 
                build_summary_tuple(V, H);
               resize_transfer -> 
                build_summary_tuple(V, Rz);
                        repair -> 
                build_summary_tuple(V, Rp)
        end
      end, Ongoing).

build_summary_tuple(Data, Total) ->
    C = length(Data),
    O = max(Total - C, C),
    T = max(Total, C),
    {C, O, T, Data}.


%% TODO: collapse into less functions where functional heads match i.e., ownership and resize
-spec outstanding_count(ho_type(), riak_core_ring:riak_core_ring()) -> [{node(), pos_integer()}].
outstanding_count(ownership_transfer, Ring) ->
    OwnershipChanges = riak_core_ring:pending_changes(Ring),
    lists:foldl(fun
                  ({_, _, '$resize', _, _}, Acc) ->
                        Acc;
                  ({_, Source, _, _, awaiting}, Acc) ->
                        OldCount = case lists:keyfind(Source, 1, Acc) of
                                       false -> 0;
                                       {Source, OC} -> OC
                                   end,
                        lists:keystore(Source, 1, Acc, {Source, OldCount + 1});
                   (_, Acc) ->
                        Acc
                end, [], OwnershipChanges);
outstanding_count(hinted_handoff, Ring) ->
    [begin
         {_, Sec, _} = riak_core_status:partitions(Node, Ring),
         {Node, length(Sec)}
     end || Node <- riak_core_ring:ready_members(Ring)];
outstanding_count(resize_transfer, Ring) ->
    Resizes = riak_core_ring:pending_changes(Ring),
    % FIXME: Is this even correct? vvvvv
    lists:foldl(fun({_, Source, '$resize', _, awaiting}, Acc) ->
                        OldCount = case lists:keyfind(Source, 1, Acc) of
                                       false -> 0;
                                       {Source, OC} -> OC
                                   end,
                        lists:keystore(Source, 1, Acc, {Source, OldCount + 1});
                   (_, Acc) ->
                        Acc
                end, [], Resizes);
outstanding_count(repair, _Ring) ->
    %% Output should [{Node, Count}]
    {Repairs, _Down} = riak_core_util:rpc_every_member_ann(riak_core_vnode_manager, all_repairs, [], 5000),
    lists:foldl(fun count_repairs/2, [], Repairs).

count_repairs({Node, RepairRecords}, Acc) ->
    [ {Node, length(RepairRecords)} | Acc ].

ongoing_transfers_summary() ->
    %% TODO (jwest): have option to use cluster metadata instead of this rpc
    %% TODO (jwest): deal w/ down nodes
    %%
    %% TODO (jwest): is rpc_every_member_ann chatting w/ more nodes than we need to (e.g. only valid, leaving?)
    %% mallen: rpc_every_member_ann calls multirpc_ann which gets its ring state and membership information from the
    %% local ring manager, so its view of the world will be the same as the status code
    {Ongoing, DownNodes} = riak_core_util:rpc_every_member_ann(
                            riak_core_handoff_manager, status,
                            [{direction, outbound}], 5000),

    Summary = lists:foldl(fun build_ongoing_node_summaries/2, 
                                            orddict:new(), Ongoing),

    %% Summary is an orddict of node -> handoff_type_counts
    %% DownNodes is a list of node() atoms
    {Summary, DownNodes}.

build_ongoing_node_summaries({Node, OutboundTransfers}, Acc) ->
    orddict:store(Node, build_summaries(OutboundTransfers), Acc).

build_summaries(OutboundTransfers) ->
    I = orddict:from_list(
          [
               {ownership_transfer, []}, 
               {hinted_handoff, []}, 
               {resize_transfer, []}, 
               {repair, []}
          ]),
    lists:foldl(fun store_handoff_by_type/2, I, OutboundTransfers).

store_handoff_by_type({status_v2, Status}, D) ->
    {_, Type} = lists:keyfind(type, 1, Status),
    orddict:append(Type, Status, D).