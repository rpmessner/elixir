%% Handle code related to match/after/else and guard
%% clauses for receive/case/fn and friends. try is
%% handled in elixir_try.
-module(elixir_try).
-export([clauses/3]).
-import(elixir_translator, [translate/2, translate_each/2]).
-import(elixir_variables, [umergec/2]).
-include("elixir.hrl").

clauses(Line, Clauses, S) ->
  DecoupledClauses = elixir_kv_block:decouple(Clauses),
  { Catch, Rescue } = lists:partition(fun(X) -> element(1, X) == 'catch' end, DecoupledClauses),
  Transformer = fun(X, Acc) -> each_clause(Line, X, umergec(S, Acc)) end,
  lists:mapfoldl(Transformer, S, Rescue ++ Catch).

each_clause(Line, {'catch',Raw,Expr}, S) ->
  { Args, Guards } = elixir_clauses:extract_last_guards(Raw),
  validate_args('catch', Line, Args, 3, S),

  Final = case Args of
    [X]     -> [throw, X, { '_', Line, nil }];
    [X,Y]   -> [X, Y, { '_', Line, nil }];
    [_,_,_] -> Args;
    [] ->
      elixir_errors:syntax_error(Line, S#elixir_scope.filename, "no condition given for: ", "catch");
    _ ->
      elixir_errors:syntax_error(Line, S#elixir_scope.filename, "too many conditions given for: ", "catch")
  end,

  Condition = { '{}', Line, Final },
  elixir_clauses:assigns_block(Line, fun elixir_translator:translate_each/2, Condition, [Expr], Guards, S);

each_clause(Line, { rescue, Args, Expr }, S) ->
  validate_args(rescue, Line, Args, 3, S),
  [Condition] = Args,
  { Left, Right } = normalize_rescue(Line, Condition, S),

  case Left of
    { '_', _, _ } ->
      case Right of
        nil ->
          each_clause(Line, { 'catch', [error, Left], Expr }, S);
        _ ->
          { ClauseVar, CS } = elixir_variables:build_ex(Line, S),
          { Clause, _ } = rescue_guards(Line, ClauseVar, Right, S),
          each_clause(Line, { 'catch', [error, Clause], Expr }, CS)
      end;
    _ ->
      { Clause, Safe } = rescue_guards(Line, Left, Right, S),
      case Safe of
        true ->
          each_clause(Line, { 'catch', [error, Clause], Expr }, S);
        false ->
          { ClauseVar, CS }  = elixir_variables:build_ex(Line, S),
          { FinalClause, _ } = rescue_guards(Line, ClauseVar, Right, S),
          Match = { '=', Line, [
            Left,
            { { '.', Line, ['::Exception', normalize] }, Line, [ClauseVar] }
          ] },
          FinalExpr = prepend_to_block(Line, Match, Expr),
          each_clause(Line, { 'catch', [error, FinalClause], FinalExpr }, CS)
      end
  end;

each_clause(Line, {Key,_,_}, S) ->
  elixir_errors:syntax_error(Line, S#elixir_scope.filename, "invalid key: ", atom_to_list(Key)).

%% Helpers

validate_args(Clause, Line, [], _, S) ->
  elixir_errors:syntax_error(Line, S#elixir_scope.filename, "no condition given for: ", atom_to_list(Clause));

validate_args(Clause, Line, List, Max, S) when length(List) > Max ->
  elixir_errors:syntax_error(Line, S#elixir_scope.filename, "too many conditions given for: ", atom_to_list(Clause));

validate_args(_, _, _, _, _) -> [].

%% rescue [Error] -> _ in [Error]
normalize_rescue(Line, List, S) when is_list(List) ->
  normalize_rescue(Line, { in, Line, [{ '_', Line, nil }, List] }, S);

%% rescue _    -> _ in _
%% rescue var  -> var in _
normalize_rescue(_, { Name, Line, Atom } = Rescue, S) when is_atom(Name), is_atom(Atom) ->
  normalize_rescue(Line, { in, Line, [Rescue, { '_', Line, nil }] }, S);

%% rescue var in _
%% rescue var in [Exprs]
normalize_rescue(_, { in, Line, [Left, Right] }, S) ->
  case Right of
    { '_', _, _ } ->
      { Left, nil };
    _ when is_list(Right), Right /= [] ->
      { _, Refs } = lists:partition(fun(X) -> element(1, X) == '^' end, Right),
      { TRefs, _ } = translate(Refs, S),
      case lists:all(fun(X) -> is_tuple(X) andalso element(1, X) == atom end, TRefs) of
        true -> { Left, Right };
        false -> normalize_rescue(Line, nil, S)
      end;
    _ -> normalize_rescue(Line, nil, S)
  end;

%% rescue ^var -> _ in [^var]
%% rescue ErlangError -> _ in [ErlangError]
normalize_rescue(_, { Name, Line, _ } = Rescue, S) when is_atom(Name) ->
  normalize_rescue(Line, { in, Line, [{ '_', Line, nil }, [Rescue]] }, S);

normalize_rescue(Line, _, S) ->
  elixir_errors:syntax_error(Line, S#elixir_scope.filename, "invalid condition for: ", "rescue").

%% Convert rescue clauses into guards.
rescue_guards(_, Var, nil, _) -> { Var, false };

rescue_guards(Line, Var, Guards, S) ->
  { Elixir, Erlang, Safe } = rescue_each_guard(Line, Var, Guards, [], [], true, S),

  Final = case Elixir == [] of
    true  -> Erlang;
    false ->
      IsTuple     = { is_tuple, Line, [Var] },
      IsException = { '==', Line, [
        { element, Line, [2, Var] },
        { '__EXCEPTION__', Line, nil }
      ] },
      OrElse = join(Line, 'orelse', Elixir),
      [join(Line, '&', [IsTuple, IsException, OrElse])|Erlang]
  end,

  {
    { 'when', Line, [Var, join(Line, '|', Final)] },
    Safe
  }.

%% Handle each clause expression detecting if it is
%% an Erlang exception or not.

rescue_each_guard(Line, Var, [{ '^', _, [H]}|T], Elixir, Erlang, _Safe, S) ->
  rescue_each_guard(Line, Var, T, [exception_compare(Line, Var, H)|Elixir], Erlang, false, S);

rescue_each_guard(Line, Var, ['::UndefinedFunctionError'|T], Elixir, Erlang, _Safe, S) ->
  Expr = { '==', Line, [Var, undef] },
  rescue_each_guard(Line, Var, T, Elixir, [Expr|Erlang], false, S);

rescue_each_guard(Line, Var, ['::ErlangError'|T], Elixir, Erlang, _Safe, S) ->
  IsNotTuple  = { 'not', Line, [{ is_tuple, Line, [Var] }] },
  IsException = { '!=', Line, [
    { element, Line, [2, Var] },
    { '__EXCEPTION__', Line, nil }
  ] },

  Expr = { 'orelse', Line, [IsNotTuple, IsException] },
  rescue_each_guard(Line, Var, T, Elixir, [Expr|Erlang], false, S);

rescue_each_guard(Line, Var, [H|T], Elixir, Erlang, Safe, S) when is_atom(H) ->
  rescue_each_guard(Line, Var, T, [exception_compare(Line, Var, H)|Elixir], Erlang, Safe, S);

rescue_each_guard(Line, Var, [H|T], Elixir, Erlang, Safe, S) ->
  case translate_each(H, S) of
    { { atom, _, Atom }, _ } ->
      rescue_each_guard(Line, Var, [Atom|T], Elixir, Erlang, Safe, S);
    _ ->
      rescue_each_guard(Line, Var, T, [exception_compare(Line, Var, H)|Elixir], Erlang, Safe, S)
  end;

rescue_each_guard(_, _, [], Elixir, Erlang, Safe, _) ->
  { Elixir, Erlang, Safe }.

%% Join the given expression forming a tree according to the given kind.

exception_compare(Line, Var, Expr) ->
  { '==', Line, [
    { element, Line, [1, Var] },
    Expr
  ] }.

join(Line, Kind, [H|T]) ->
  lists:foldl(fun(X, Acc) -> { Kind, Line, [Acc, X] } end, H, T).

prepend_to_block(_Line, Expr, { '__BLOCK__', Line, Args }) ->
  { '__BLOCK__', Line, [Expr|Args] };

prepend_to_block(Line, Expr, Args) ->
  { '__BLOCK__', Line, [Expr, Args] }.