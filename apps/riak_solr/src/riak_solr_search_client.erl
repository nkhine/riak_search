%% -------------------------------------------------------------------
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% -------------------------------------------------------------------

-module(riak_solr_search_client, [RiakClient, SearchClient]).
-export([parse_solr_xml/2,
         run_solr_command/3
]).

-define(DEFAULT_INDEX, "search").
-define(DEFAULT_TIMEOUT, 60000).

-include_lib("riak_search/include/riak_search.hrl").

%% Parse a solr XML formatted file.
parse_solr_xml(IndexOrSchema, Body) when is_binary(Body) ->
    %% Get the schema...
    {ok, Schema} = riak_search_config:get_schema(IndexOrSchema),
    Index = Schema:name(),

    %% Parse the xml...
    {ok, Command, Entries} = riak_solr_xml_xform:xform(Body),

    ParsedDocs = [parse_solr_entry(Index, Command, X) || X <- Entries],
    {ok, Command, ParsedDocs}.

%% @private
%% Parse a document to add...
parse_solr_entry(Index, add, {"doc", Entry}) ->
    IdxDoc = to_riak_idx_doc(Index, Entry),
    {ok, Postings} = riak_indexed_doc:analyze(IdxDoc),
    {IdxDoc, Postings};
 
%% Deletion by ID or Query. If query, then parse...
parse_solr_entry(Index, delete, {"id", ID}) ->
    case string:tokens(binary_to_list(ID), ":") of
        [] ->
            throw({?MODULE, empty_id_on_solr_delete});
        [H] -> 
            {'id', Index, H};
        [H|T] -> 
            {'id', H, string:join(T, ":")}
    end;
parse_solr_entry(Index, delete, {"query", Query}) ->
    case SearchClient:parse_query(Index, binary_to_list(Query)) of
        {ok, QueryOps} ->
            {'query', QueryOps};
        {error, Error} ->
            M = "Error parsing query '~s': ~p~n",
            error_logger:error_msg(M, [Query, Error]),
            throw({?MODULE, could_not_parse_query, Query})
    end;

%% Some unknown command...
parse_solr_entry(_, Command, Entry) ->
    throw({?MODULE, unknown_command, Command, Entry}).


%% @private
to_riak_idx_doc(Index, Doc) ->
    case lists:keyfind("id", 1, Doc) of
        {"id", Id} ->
            Id;
        false ->
            Id = undefined, % Prevent compiler warnings.
            throw({?MODULE, required_field_not_found, "id", Doc})
    end,
    Fields = lists:keydelete("id", 1, Doc),
    #riak_idx_doc{id=Id, index=Index, fields=Fields, props=[]}.


%% Run the provided solr command on the provided docs...
run_solr_command(_, _, []) ->
    ok;

%% Add a list of documents to the index...
run_solr_command(Schema, add, [{IdxDoc, Terms}|Docs]) ->
    %% If there is an old document, then delete it.
    delete_doc(Schema:name(), IdxDoc#riak_idx_doc.id),
    
    %% Store the terms...
    SearchClient:index_terms(Terms),

    %% Store the document.
    riak_indexed_doc:put(RiakClient, IdxDoc),
    run_solr_command(Schema, add, Docs);

%% Delete a document by ID...
run_solr_command(Schema, delete, [{'id', Index, ID}|IDs]) ->
    delete_doc(Index, ID),
    run_solr_command(Schema, delete, IDs);

%% Delete documents by query...
run_solr_command(Schema, delete, [{'query', QueryOps}|Queries]) ->
    Index = Schema:name(),
    {_NumFound, _MaxScore, Docs} = SearchClient:search_doc(Schema, QueryOps, 0, infinity, ?DEFAULT_TIMEOUT),
    [delete_doc(Index, X#riak_idx_doc.id) || X <- Docs, X /= {error, notfound}],
    run_solr_command(Schema, delete, Queries);

%% Unknown command, so error...
run_solr_command(_Schema, Command, _Docs) ->
    error_logger:error_msg("Unknown solr command: ~p~n", [Command]),
    throw({unknown_solr_command, Command}).

%% ensure_deleted(Index, DocID) ->
%%     case riak_indexed_doc:get(RiakClient, Index, DocID) of
%%         {error, notfound} -> 
%%             ok;
%%         _ ->
%%             SearchClient:delete_doc(Index, DocID),
%%             timer:sleep(10),
%%             ensure_deleted(Index, DocID)
%%     end.

delete_doc(Index, DocId) ->
    case riak_indexed_doc:get(RiakClient, Index, DocId) of
        {error, notfound} ->
            {error, notfound};
        IdxDoc ->
            {ok, AnalyzerPid} = qilr:new_analyzer(),
            try 
                SearchClient:delete_doc(IdxDoc, AnalyzerPid)
            after
                qilr:close_analyzer(AnalyzerPid)
            end,
            ok
    end.
