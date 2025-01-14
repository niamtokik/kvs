-module(kvs_st).
-include("kvs.hrl").
-include("stream.hrl").
-include("metainfo.hrl").
-export(?STREAM).
-import(kvs_rocks, [key/2, key/1, bt/1, tb/1, ref/0, seek_it/1, move_it/3, take_it/4, estimate/0]).
-export([raw_append/2]).

se(X,Y,Z) -> setelement(X,Y,Z).
e(X,Y) -> element(X,Y).
c4(R,V) -> se(#reader.args,  R, V).
si(M,T) -> se(#it.id, M, T).
id(T) -> e(#it.id, T).

k(F,[]) -> F;
k(_,{_,Id,SF}) -> iolist_to_binary([SF,<<"/">>,tb(Id)]).

f2(Feed) -> X = tb(Feed),
  case binary:matches(X, <<"/">>,[]) of
    [{0,1}|_] -> binary:part(X,{1,size(X)-1});
            _ -> X
  end.

read_it(C,{ok,_,[],H}) -> C#reader{cache=[], args=lists:reverse(H)};
read_it(C,{ok,F,V,H})  -> C#reader{cache={e(1,V),id(V),F}, args=lists:reverse(H)};
read_it(C,_) -> C#reader{args=[]}.

top(#reader{feed=Feed}=C) -> #writer{count=Cn} = writer(f2(Feed)), read_it(C#reader{count=Cn},seek_it(Feed)).
bot(#reader{feed=Feed}=C) -> #writer{cache=Ch, count=Cn} = writer(f2(Feed)), C#reader{cache=Ch, count=Cn}.
next(#reader{feed=Feed,cache=I}=C) -> read_it(C,move_it(k(Feed,I),Feed,next)).
prev(#reader{cache=I,feed=Feed}=C) -> read_it(C,move_it(k(Feed,I),Feed,prev)).
take(#reader{args=N,feed=Feed,cache=I,dir=1}=C) -> read_it(C,take_it(k(Feed,I),Feed,prev,N));
take(#reader{args=N,feed=Feed,cache=I,dir=_}=C) -> read_it(C,take_it(k(Feed,I),Feed,next,N)).
drop(#reader{args=N}=C) when N =< 0 -> C;
drop(#reader{}=C) -> (take(C#reader{dir=0}))#reader{args=[]}.

feed(Feed) ->
  #reader{count=Cn} = Top = top(reader(Feed)),
  Halt = case {estimate(),Cn} of 
          {E,C} when E =< 0 -> max(C,4);
          {E,_} -> E
         end,
  feed(fun(#reader{}=R) -> take(R#reader{args=4}) end,Top,[],Halt).

feed(F,#reader{},Acc,H) when H =< 0 -> Acc;
feed(F,#reader{cache=C1,count=Cn}=R,Acc,H) ->
  #reader{args=A, cache=Ch, feed=Feed} = R1 = F(R),
  case Ch of
    C1 -> Acc ++ A;
    {_,_,K} when binary_part(K,{0,byte_size(Feed)}) == Feed
            andalso length(A) == 4
      -> feed(F, R1, Acc ++ A, H-4);
    _ -> Acc ++ A
  end.

load_reader(Id) -> case kvs:get(reader,Id) of {ok,#reader{}=C} -> C; _ -> #reader{id=kvs:seq([],[])} end.

writer(Id) -> case kvs:get(writer,Id) of {ok,W} -> W; {error,_} -> #writer{id=Id} end.
reader(Id) -> case kvs:get(writer,Id) of
  {ok,#writer{id=Feed, count=Cn, cache=Ch}} ->
    read_it(#reader{id=kvs:seq([],[]),feed=key(Feed),count=Cn,cache=Ch},seek_it(key(Feed)));
  {error,_} ->
    read_it(#reader{id=kvs:seq([],[]),feed=key(Id),count=0,cache=[]},seek_it(key(Id)))
  end.
save(C) ->
  N1 = case id(C) of [] -> si(C,kvs:seq([],[])); _ -> C end,
  NC = c4(N1,[]),
  kvs:put(NC), NC.

% add

raw_append(M,Feed) -> rocksdb:put(ref(), key(Feed,e(2,M)), term_to_binary(M), [{sync,true}]).

add(#writer{args=M}=C) when element(2,M) == [] -> add(si(M,kvs:seq([],[])),C);
add(#writer{args=M}=C) -> add(M,C).

add(M,#writer{id=Feed,count=S}=C) ->
   NS=S+1,
   raw_append(M,Feed),
   C#writer{cache={e(1,M),e(2,M),key(Feed)},count=NS}.

remove(Rec,Feed) ->
  kvs:ensure(#writer{id=Feed}),
  W = #writer{count=C, cache=Ch} = kvs:writer(Feed),
  Ch1 = case {e(1,Rec),e(2,Rec),key(Feed)} of % need to keep reference for next element
              Ch -> R = reader(Feed), e(4, prev(R#reader{cache=Ch}));
              _ -> Ch end,
  case kvs:delete(Feed,id(Rec)) of
        ok -> Count = C - 1,
              save(W#writer{count = Count, cache=Ch1}),
              Count;
        _ -> C end.

append(Rec,Feed) ->
   kvs:ensure(#writer{id=Feed}),
   Id = e(2,Rec),
   W = writer(Feed),
   case kvs:get(Feed,Id) of
        {ok,_} -> raw_append(Rec,Feed), Id;
        {error,_} -> save(add(W#writer{args=Rec})), Id end.
