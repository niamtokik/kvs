-module(kvs).

-behaviour(application).

-behaviour(supervisor).

-include_lib("stdlib/include/assert.hrl").

-include("api.hrl").

-include("metainfo.hrl").

-include("stream.hrl").

-include("cursors.hrl").

-include("kvs.hrl").

-include("backend.hrl").

-export([dump/0,
         metainfo/0,
         ensure/1,
         seq_gen/0,
         fields/1,
         defined/2,
         field/2,
         setfield/3,
         cut/2]).

-export([join/2, seq/3]).

-export(?API)

.

-export(?STREAM)

.

-export([init/1, start/2, stop/1]).

-record('$msg', {id, next, prev, user, msg}).

init([]) -> {ok, {{one_for_one, 5, 10}, []}}.

start(_, _) ->
    supervisor:start_link({local, kvs}, kvs, []).

stop(_) -> ok.

dba() -> application:get_env(kvs, dba, kvs_mnesia).

kvs_stream() ->
    application:get_env(kvs, dba_st, kvs_stream).

% kvs api

all(Table) -> all(Table, #kvs{mod = dba()}).

delete(Table, Key) ->
    delete(Table, Key, #kvs{mod = dba()}).

get(Table, Key) ->
    (?MODULE):get(Table, Key, #kvs{mod = dba()}).

index(Table, K, V) ->
    index(Table, K, V, #kvs{mod = dba()}).

join() -> join([], #kvs{mod = dba()}).

dump() -> dump(#kvs{mod = dba()}).

join(Node) -> join(Node, #kvs{mod = dba()}).

leave() -> leave(#kvs{mod = dba()}).

destroy() -> destroy(#kvs{mod = dba()}).

count(Table) -> count(Table, #kvs{mod = dba()}).

put(Record) -> (?MODULE):put(Record, #kvs{mod = dba()}).

stop() -> stop_kvs(#kvs{mod = dba()}).

start() -> start(#kvs{mod = dba()}).

ver() -> ver(#kvs{mod = dba()}).

dir() -> dir(#kvs{mod = dba()}).

feed(Key) ->
    feed(Key, #kvs{mod = dba(), st = kvs_stream()}).

seq(Table, DX) -> seq(Table, DX, #kvs{mod = dba()}).

remove(Rec, Feed) ->
    remove(Rec, Feed, #kvs{mod = dba(), st = kvs_stream()}).

put(Records, #kvs{mod = Mod}) when is_list(Records) ->
    Mod:put(Records);
put(Record, #kvs{mod = Mod}) -> Mod:put(Record).

get(RecordName, Key, #kvs{mod = Mod}) ->
    Mod:get(RecordName, Key).

delete(Tab, Key, #kvs{mod = Mod}) ->
    Mod:delete(Tab, Key).

count(Tab, #kvs{mod = DBA}) -> DBA:count(Tab).

index(Tab, Key, Value, #kvs{mod = DBA}) ->
    DBA:index(Tab, Key, Value).

seq(Tab, Incr, #kvs{mod = DBA}) -> DBA:seq(Tab, Incr).

dump(#kvs{mod = Mod}) -> Mod:dump().

feed(Tab, #kvs{st = Mod}) -> Mod:feed(Tab).

remove(Rec, Feed, #kvs{st = Mod}) ->
    Mod:remove(Rec, Feed).

all(Tab, #kvs{mod = DBA}) -> DBA:all(Tab).

start(#kvs{mod = DBA}) -> DBA:start().

stop_kvs(#kvs{mod = DBA}) -> DBA:stop().

join(Node, #kvs{mod = DBA}) -> DBA:join(Node).

leave(#kvs{mod = DBA}) -> DBA:leave().

destroy(#kvs{mod = DBA}) -> DBA:destroy().

ver(#kvs{mod = DBA}) -> DBA:version().

dir(#kvs{mod = DBA}) -> DBA:dir().

% stream api

top(X) -> (kvs_stream()):top(X).

bot(X) -> (kvs_stream()):bot(X).

next(X) -> (kvs_stream()):next(X).

prev(X) -> (kvs_stream()):prev(X).

drop(X) -> (kvs_stream()):drop(X).

take(X) -> (kvs_stream()):take(X).

save(X) -> (kvs_stream()):save(X).

cut(X, Y) -> (kvs_stream()):cut(X, Y).

add(X) -> (kvs_stream()):add(X).

append(X, Y) -> (kvs_stream()):append(X, Y).

load_reader(X) -> (kvs_stream()):load_reader(X).

writer(X) -> (kvs_stream()):writer(X).

reader(X) -> (kvs_stream()):reader(X).

% unrevisited

ensure(#writer{id = Id}) ->
    case kvs:get(writer, Id) of
        {error, _} ->
            kvs:save(kvs:writer(Id)),
            ok;
        {ok, _} -> ok
    end.

cursors() ->
    lists:flatten([[{T#table.name, T#table.fields}
                    || #table{name = Name} = T
                           <- (M:metainfo())#schema.tables,
                       Name == reader orelse Name == writer]
                   || M <- modules()]).

% metainfo api

tables() ->
    lists:flatten([(M:metainfo())#schema.tables
                   || M <- modules()]).

modules() -> application:get_env(kvs, schema, []).

metainfo() ->
    #schema{name = kvs, tables = core() ++ test_tabs()}.

core() ->
    [#table{name = id_seq,
            fields = record_info(fields, id_seq), keys = [thing]}].

test_tabs() ->
    [#table{name = '$msg',
            fields = record_info(fields, '$msg')}].

table(Name) when is_atom(Name) ->
    lists:keyfind(Name, #table.name, tables());
table(_) -> false.

seq_gen() ->
    Init = fun (Key) ->
                   case kvs:get(id_seq, Key) of
                       {error, _} ->
                           {Key, kvs:put(#id_seq{thing = Key, id = 0})};
                       {ok, _} -> {Key, skip}
                   end
           end,
    [Init(atom_to_list(Name))
     || {Name, _Fields} <- cursors()].

initialize(Backend, Module) ->
    [begin
         Backend:create_table(T#table.name,
                              [{attributes, T#table.fields},
                               {T#table.copy_type, [node()]},
                               {type, T#table.type}]),
         [Backend:add_table_index(T#table.name, Key)
          || Key <- T#table.keys],
         T
     end
     || T <- (Module:metainfo())#schema.tables].

fields(Table) when is_atom(Table) ->
    case table(Table) of
        false -> [];
        T -> T#table.fields
    end.

defined(TableRecord, Field) ->
    FieldsList = fields(element(1, TableRecord)),
    lists:member(Field, FieldsList).

field(TableRecord, Field) ->
    FieldsList = fields(element(1, TableRecord)),
    Index = string:str(FieldsList, [Field]) + 1,
    element(Index, TableRecord).

setfield(TableRecord, Field, Value) ->
    FieldsList = fields(element(1, TableRecord)),
    Index = string:str(FieldsList, [Field]) + 1,
    setelement(Index, TableRecord, Value).
