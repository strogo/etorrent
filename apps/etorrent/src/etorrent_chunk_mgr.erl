%%%-------------------------------------------------------------------
%%% File    : etorrent_chunk_mgr.erl
%%% Author  : Jesper Louis Andersen <jlouis@ogre.home>
%%% Description : Chunk manager of etorrent.
%%%
%%% Created : 20 Jul 2008 by Jesper Louis Andersen <jlouis@ogre.home>
%%%-------------------------------------------------------------------
-module(etorrent_chunk_mgr).

-include("etorrent_chunk.hrl").
-include("types.hrl").
-include("log.hrl").

-include_lib("stdlib/include/ms_transform.hrl").

-behaviour(gen_server).

%% @todo: What pid is the chunk recording pid? Control or SendPid?
%% API
-export([start_link/0, store_chunk/3, putback_chunks/1,
         mark_fetched/2, pick_chunks/3,
         new/1, endgame_remove_chunk/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, { torrent_dict,
	         monitored_peers = gb_sets:empty() }).
-define(SERVER, ?MODULE).
-define(TAB, etorrent_chunk_tbl).
-define(STORE_CHUNK_TIMEOUT, 20).
-define(PICK_CHUNKS_TIMEOUT, 20).


-ignore_xref([{start_link, 0}]).

%%====================================================================
-spec start_link() -> ignore | {ok, pid()} | {error, any()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Mark a given chunk as fetched.
%% @end
-spec mark_fetched(integer(), {integer(), integer(), integer()}) -> found | assigned.
mark_fetched(Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {mark_fetched, Id, Index, Offset, Len}).

%% @doc Store the chunk in the chunk table.
%%   As a side-effect, check the piece if it is fully fetched.
%% @end
-spec store_chunk(integer(), {integer(), integer(), binary()}, pid()) -> ok.
store_chunk(Id, {Index, Offset, D}, FSPid) ->
    gen_server:cast(?SERVER, {store_chunk, Id, self(), {Index, Offset, D}, FSPid}).

%%--------------------------------------------------------------------
%% Function: putback_chunks(Pid) -> transaction
%% Description: Find all chunks assigned to Pid and mark them as not_fetched
%%--------------------------------------------------------------------
-spec putback_chunks(pid()) -> ok.
putback_chunks(Pid) ->
    gen_server:cast(?SERVER, {putback_chunks, Pid}).

%%--------------------------------------------------------------------
%% Function: endgame_remove_chunk/3
%% Args:  Pid ::= pid()     - pid of caller
%%        Id  ::= integer() - torrent id
%%        IOL ::= {integer(), integer(), integer()} - {Index, Offs, Len}
%% Description: Remove a chunk in the endgame from its assignment to a
%%   given pid
%%--------------------------------------------------------------------
-spec endgame_remove_chunk(pid(), integer(), {integer(), integer(), integer()}) -> ok.
endgame_remove_chunk(SendPid, Id, {Index, Offset, Len}) ->
    gen_server:call(?SERVER, {endgame_remove_chunk, SendPid, Id, {Index, Offset, Len}},
		    infinity).

%% @doc Return some chunks for downloading.
%% @end
-type chunk_lst() :: [{integer(), [{integer(), integer()}]}].
-spec pick_chunks(integer(), unknown | gb_set(), integer()) ->
    none_eligible | not_interested | {ok | endgame, chunk_lst()}.
pick_chunks(_Id, unknown, _N) ->
    none_eligible;
pick_chunks(Id, Set, N) ->
    case pick_chunks(pick_chunked, {self(), Id, Set, [], N, none}) of
	not_interested -> pick_chunks_endgame(Id, Set, N, not_interested);
	{ok, []}       -> pick_chunks_endgame(Id, Set, N, none_eligible);
	{ok, Items}    -> {ok, Items}
    end.

% @doc Request the managing of a new torrent identified by Id
% <p>Note that the calling Pid is tracked as being the owner of the torrent.
% If the calling Pid dies, then the torrent will be assumed stopped</p>
% @end
-spec new(integer()) -> ok.
new(Id) ->
    gen_server:call(?SERVER, {new, Id}, infinity).

%% ----------------------------------------------------------------------

%% @doc Choose up to Max chunks from Selected.
%%  Will return {ok, {Index, Chunks}, size(Chunks)}.
%% @end
-spec select_chunks_by_piecenum({pos_integer(), pos_integer()}, pos_integer()) ->
			   {ok, {pos_integer(), term()}, non_neg_integer()} | {error, already_taken}.
select_chunks_by_piecenum({TorrentId, Pn}, Max) ->
    gen_server:call(?SERVER, {select_chunks_by_piecenum, {TorrentId, Pn}, Max},
		    infinity).


%%====================================================================
init([]) ->
    _Tid = ets:new(?TAB, [bag, protected, named_table, {keypos, #chunk.idt}]),
    D = dict:new(),
    {ok, #state{ torrent_dict = D }}.

handle_call({new, Id}, {Pid, _Tag}, S) ->
    ManageDict = dict:store(Pid, Id, S#state.torrent_dict),
    _ = erlang:monitor(process, Pid),
    {reply, ok, S#state { torrent_dict = ManageDict }};
handle_call({mark_fetched, Id, Index, Offset, _Len}, _From, S) ->
    case ets:match_object(?TAB, #chunk { idt = {Id, Index, not_fetched},
					 chunk = {Offset, '_'} }) of
	[] -> {reply, assigned, S};
	[Obj] -> ets:delete_object(?TAB, Obj),
		 {reply, found, S}
    end;
%% @todo: If we have an idt with {assigned, pid()}, do we have chunk = Offset?
handle_call({select_chunks_by_piecenum, {Id, Pn}, Max}, {Pid, _Tag}, S) ->
    case ets:lookup(?TAB, {Id, Pn, not_fetched}) of
	[] ->
	    {reply, {error, already_taken}, S};
	Selected when is_list(Selected) ->
	    %% Get up to Max chunks
	    {Return, _Rest} = etorrent_utils:gsplit(Max, Selected),
	    %% Assign chunk to Pid
	    Chunks = [begin
			  ets:delete_object(?TAB, C),
			  ets:insert(?TAB,
				     [C#chunk {
				idt = {Id, Pn, {assigned, Pid}} }]),
			  C#chunk.chunk
		      end || C <- Return],
	    MP = ensure_monitor(Pid, S#state.monitored_peers),
	    {reply,
	     {ok, {Pn, Chunks}, length(Chunks)},
	     S#state { monitored_peers = MP }}
    end;
handle_call({chunkify_piece, {Id, Pn}}, _From, S) ->
    chunkify_piece(Id, Pn),
    {reply, ok, S};
handle_call({endgame_remove_chunk, SendPid, Id, {Index, Offset, _Len}},
            _From, S) ->
    ets:match_delete(?TAB,
		      #chunk { idt = {Id, Index, {assigned, SendPid}},
			       chunk = Offset }),
    {reply, ok, S};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

ensure_monitor(Pid, Set) ->
    case gb_sets:is_member(Pid, Set) of
	true ->
	    Set;
	false ->
	    erlang:monitor(process, Pid),
	    gb_sets:add(Pid, Set)
    end.

handle_cast({store_chunk, Id, Pid, {Index, Offset, Data}, FSPid}, S) ->
    ok = etorrent_io:write_chunk(Id, Index, Offset, Data),
    %% Add the newly fetched data to the fetched list
    Present = update_fetched(Id, Index, {Offset, byte_size(Data)}),
    %% Update chunk assignment
    update_chunk_assignment(Id, Index, Pid, {Offset, byte_size(Data)}),
    %% Countdown number of missing chunks
    case Present of
        fetched -> ok;
        true    -> ok;
        false   ->
            case etorrent_piece_mgr:decrease_missing_chunks(Id, Index) of
                full -> check_piece(FSPid, Id, Index);
                X    -> X
            end
    end,
    {noreply, S};
% @todo This only works if {assigned, pid()} has chunks as a 3-tuple
handle_cast({putback_chunks, Pid}, S) ->
    remove_chunks_for_pid(Pid),
    {noreply, S};
handle_cast(Msg, State) ->
    ?WARN([unknown_msg, Msg]),
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    case dict:find(Pid, S#state.torrent_dict) of
	{ok, Id} ->
	    clear_torrent_entries(Id),
	    ManageDict = dict:erase(Pid, S#state.torrent_dict),
	    {noreply, S#state { torrent_dict = ManageDict }};
	error ->
	    %% Not found, assume it is a Pid of a process
	    remove_chunks_for_pid(Pid),
	    {noreply, S#state { monitored_peers =
				  gb_sets:del_element(Pid,
						      S#state.monitored_peers) }}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%--------------------------------------------------------------------

%% @doc Find all entries for a given torrent file and clear them out
%% @end
clear_torrent_entries(Id) ->
    ets:match_delete(?TAB, #chunk { idt = {Id, '_', '_'}, chunk = '_'}).

%% @doc Find all remaining chunks for a torrent matching PieceSet
%% @end
%% @todo Consider using ets:fun2ms here to parse-transform the matches
-spec find_remaining_chunks(integer(), set()) ->
    [{integer(), integer(), integer()}].
find_remaining_chunks(Id, PieceSet) ->
    %% Note that the chunk table is often very small.
    MatchHeadAssign = #chunk { idt = {Id, '$1', {assigned, '_'}}, chunk = '$2'},
    MatchHeadNotFetch = #chunk { idt = {Id, '$1', not_fetched}, chunk = '$2'},
    RowsA = ets:select(?TAB, [{MatchHeadAssign, [], [{{'$1', '$2'}}]}]),
    RowsN = ets:select(?TAB, [{MatchHeadNotFetch, [], [{{'$1', '$2'}}]}]),
    Eligible = [{PN, Chunk} || {PN, Chunk} <- RowsA ++ RowsN,
                                gb_sets:is_element(PN, PieceSet)],
    [{PN, Os, Sz} || {PN, {Os, Sz}} <- Eligible].

%% @doc Chunkify a new piece.
%%
%%  Find a piece in the PieceSet which has not been chunked
%%  yet and chunk it. Returns either ok if a piece was chunked or none_eligible
%%  if we can't find anything to chunk up in the PieceSet.
%%
%% @end
-spec chunkify_new_piece(integer(), gb_set()) -> {ok, pos_integer()} | none_eligible.
chunkify_new_piece(Id, PieceSet) when is_integer(Id) ->
    case etorrent_piece_mgr:find_new(Id, PieceSet) of
        none -> none_eligible;
        {P, Pn} when is_integer(Pn) ->
	    ok = gen_server:call(?SERVER, {chunkify_piece, {Id, P}},
				 infinity),
	    {ok, Pn}
    end.

%% Check the piece Idx on torrent Id for completion
check_piece(_, Id, Idx) ->
    _ = spawn_link(etorrent_fs_checker, check_piece, [Id, Idx]),
    ets:match_delete(?TAB, #chunk { idt = {Id, Idx, '_'}, _ = '_'}).


%% @doc Add a chunked piece to the chunk table
%%   Given a PieceNumber, cut it up into chunks and add those
%%   to the chunk table.
%% @end
-spec chunkify_piece(integer(), etorrent:piece_mgr_piece()) -> ok. %% @todo: term() is #piece{}, opaque export it
chunkify_piece(Id, P) ->
    {Id, Idx, Chunks} = etorrent_piece_mgr:chunkify_piece(Id, P),
    ets:insert(?TAB, [#chunk { idt = {Id, Idx, not_fetched}, chunk = CH }
		      || CH <- Chunks]),
    etorrent_torrent:decrease_not_fetched(Id),
    ok.

%% @doc Search for piece chunks to download from a peer
%%   We are given an iterator of the pieces the peer has. We search the
%%   the iterator for a pieces we have already chunked and are downloading.
%%   If found, return the #chunk{} object. Otherwise return 'none'
%% @end
-spec find_chunked_chunks(pos_integer(), term(), A) -> A | pos_integer().
find_chunked_chunks(_Id, none, Res) -> Res;
find_chunked_chunks(Id, {Pn, Iter}, _Res) ->
    case ets:member(?TAB, {Id, Pn, not_fetched}) of
	false ->
	    find_chunked_chunks(Id, gb_sets:next(Iter), found_chunked);
	true ->
	    Pn
    end.

update_fetched(Id, Index, {Offset, _Len}) ->
    case etorrent_piece_mgr:fetched(Id, Index) of
        true -> fetched;
        false ->
	    case ets:match_object(?TAB, #chunk { idt = {Id, Index, fetched},
						 chunk = Offset }) of
		[] ->
		    ets:insert(?TAB,
			       #chunk { idt = {Id, Index, fetched},
					chunk = Offset }),
		    false;
		[_Obj] ->
		    true
	    end
    end.

update_chunk_assignment(Id, Index, Pid,
                        {Offset, _Len}) ->
    ets:match_delete(?TAB, #chunk { idt = {Id, Index, {assigned, Pid}},
				    chunk = {Offset, '_'} }).

%%
%% There are 0 remaining chunks to be desired, return the chunks so far
pick_chunks(_Operation, {_Pid, _Id, _PieceSet, SoFar, 0, _Res}) ->
    {ok, SoFar};
%%
%% Pick chunks from the already chunked pieces
pick_chunks(pick_chunked, Tup = {_, Id, _, _, _, _}) ->
    Candidates = etorrent_piece_mgr:chunked_pieces(Id),
    CandidateSet = gb_sets:from_list(Candidates),
    pick_chunks({pick_among, CandidateSet}, Tup);
pick_chunks({pick_among, CandidateSet}, {Pid, Id, PieceSet, SoFar, Remaining, Res}) ->
    Iter = gb_sets:iterator( gb_sets:intersection(CandidateSet, PieceSet) ),
    case find_chunked_chunks(Id, gb_sets:next(Iter), Res) of
        none ->
            pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, none});
        found_chunked ->
            pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, found_chunked});
	PN when is_integer(PN) ->
	    case select_chunks_by_piecenum({Id, PN}, Remaining) of
		{ok, {PieceNum, Chunks}, Size} ->
		    pick_chunks(pick_chunked, {Pid, Id,
					       gb_sets:del_element(PieceNum, PieceSet),
					       [{PieceNum, Chunks} | SoFar],
					       Remaining - Size, Res});
		{error, already_taken} ->
		    %% So somebody else took this, try again
		    pick_chunks(pick_chunked, {Pid, Id, PieceSet, SoFar, Remaining, Res})
	    end
    end;

%%
%% Find a new piece to chunkify. Give up if no more pieces can be chunkified
pick_chunks(chunkify_piece, {Pid, Id, PieceSet, SoFar, Remaining, Res}) ->
    case chunkify_new_piece(Id, PieceSet) of
        {ok, P} ->
	    CandidateSet = gb_sets:from_list([P]),
            pick_chunks({pick_among, CandidateSet}, {Pid, Id, PieceSet, SoFar, Remaining, Res});
        none_eligible when SoFar =:= [], Res =:= none ->
            not_interested;
        none_eligible when SoFar =:= [], Res =:= found_chunked ->
            {ok, []};
        none_eligible ->
            {ok, SoFar}
    end;
%% Handle the endgame for a torrent gracefully
pick_chunks(endgame, {Id, PieceSet, N}) ->
    Remaining = find_remaining_chunks(Id, PieceSet),
    Shuffled = etorrent_utils:list_shuffle(Remaining),
    Grouped = gather(
		lists:sort(
		  lists:sublist(Shuffled, N))),
    {endgame, etorrent_utils:list_shuffle(Grouped)}.

%% Gather like pieces in the endgame
gather([]) -> [];
gather([{PN, Off, Sz} | R]) ->
    gather(PN, [{Off, Sz}], R).

gather(PN, Item, []) ->
    [{PN, lists:sort(Item)}];
gather(PN, Items, [{PN, Off, Sz} | Next]) ->
    gather(PN, [{Off, Sz} | Items], Next);
gather(PN, Items, [{PN2, Off, Sz} | Next]) ->
    [{PN, lists:sort(Items)} | gather(PN2, [{Off, Sz}], Next)].


-spec pick_chunks_endgame(integer(), gb_set(), integer(), X) -> X | {endgame, [#chunk{}]}.
pick_chunks_endgame(Id, Set, Remaining, Ret) ->
    case etorrent_torrent:is_endgame(Id) of
        false -> Ret; %% No endgame yet
        true -> pick_chunks(endgame, {Id, Set, Remaining})
    end.

remove_chunks_for_pid(Pid) ->
    for_each_chunk(
      Pid,
      fun(C) ->
	      {Id, Idx, _} = C#chunk.idt,
	      ets:insert(?TAB,
			 #chunk { idt = {Id, Idx, not_fetched},
				  chunk = C#chunk.chunk }),
	      ets:delete_object(?TAB, C)
      end).

for_each_chunk(Pid, F) when is_pid(Pid) ->
    MatchHead = #chunk { idt = {'_', '_', {assigned, Pid}}, _ = '_'},
    for_each_chunk(MatchHead, F);
for_each_chunk(MatchHead, F) ->
    Rows = ets:select(?TAB, [{MatchHead, [], ['$_']}]),
    lists:foreach(F, Rows),
    ok.
