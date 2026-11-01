defmodule Arcadic.ConnGuardProbeTest do
  @moduledoc """
  Proves the Rule-3 conn-guard contract library-wide: EVERY public function
  whose first positional argument is an `Arcadic.Conn` (or the module's own
  struct, for `Conn`/`Error`/`TransportError`) raises a VALUE-FREE
  `ArgumentError` when a wrong-typed value is passed there — never a
  `FunctionClauseError`, whose blame echoes the caller's arguments.

  The probe list is derived from the SOURCE (AST scan of `lib/`), not a
  hand-written roster, so a new facade added without a guard goes RED here
  instead of silently reopening the class (the routed S9 finding: 233
  `%Conn{}` head-matches, blame-echo on caller programming slips).
  """
  use ExUnit.Case, async: true

  @sentinel_marker "CONN_GUARD_PROBE_SENTINEL_fb3f9c"
  @guard_message_prefix "expected an Arcadic."

  defmodule Sentinel do
    @moduledoc false
    defstruct secret: "CONN_GUARD_PROBE_SENTINEL_fb3f9c"
  end

  # -- AST scan ---------------------------------------------------------------

  @lib_dir "lib"

  defp conn_first?({:=, _, [pattern, _var]}), do: struct_pattern?(pattern)
  defp conn_first?(arg), do: struct_pattern?(arg)

  defp struct_pattern?({:%, _, [module, _map]}), do: conn_module?(module)
  defp struct_pattern?(_), do: false

  defp conn_module?({:__aliases__, _, [:Conn]}), do: true
  defp conn_module?({:__MODULE__, _, _}), do: true
  defp conn_module?(_), do: false

  defp strip_default({:\\, _, [arg, _default]}), do: arg
  defp strip_default(arg), do: arg

  defp walk({:defmodule, _, [name, [do: body]]}, module, acc) do
    walk(body, qualify(module, name), acc)
  end

  defp walk({:def, _, [head, _body]}, module, acc) do
    case head do
      {:when, _, [inner | _]} -> collect(inner, module, acc)
      other -> collect(other, module, acc)
    end
  end

  defp collect({name, _, args}, module, acc) when is_atom(name) and is_list(args) do
    args = Enum.map(args, &strip_default/1)

    if args != [] and conn_first?(hd(args)) do
      [{module, name, length(args)} | acc]
    else
      acc
    end
  end

  defp collect(_, _module, acc), do: acc

  defp walk({:defp, _, _}, _module, acc), do: acc

  defp walk(node, module, acc) when is_list(node) do
    Enum.reduce(node, acc, &walk(&1, module, &2))
  end

  defp walk({_, _, children}, module, acc) when is_list(children) do
    Enum.reduce(children, acc, &walk(&1, module, &2))
  end

  defp walk(_, _, acc), do: acc

  defp qualify(nil, {:__aliases__, _, parts}), do: Module.concat(parts)
  defp qualify(parent, {:__aliases__, _, parts}), do: Module.concat(parent, parts)
  defp qualify(nil, atom) when is_atom(atom), do: atom
  defp qualify(parent, atom) when is_atom(atom), do: Module.concat(parent, atom)

  defp discover do
    Path.wildcard(Path.join(@lib_dir, "**/*.ex"))
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> walk(nil, [])
    end)
    |> MapSet.new()
  end

  # -- the probe ---------------------------------------------------------------

  test "every public conn-first function raises value-free on a wrong-typed conn" do
    targets = discover()

    # Non-vacuity floor: the guarded surface is the whole facade layer (232
    # functions at the time this probe landed). A collapsed discovery (empty or
    # tiny) means the scan itself broke.
    assert MapSet.size(targets) > 200,
           "AST discovery found only #{MapSet.size(targets)} conn-first functions"

    unguarded =
      for {module, name, arity} <- Enum.sort(MapSet.to_list(targets)),
          leak = probe(module, name, arity),
          leak != nil do
        leak
      end

    assert unguarded == [],
           "functions leaking (or not value-free-guarding) their first argument: " <>
             inspect(unguarded)
  end

  defp probe(module, name, arity) do
    sentinel = struct!(Sentinel)
    args = [sentinel | List.duplicate(:probe_unused, arity - 1)]

    try do
      apply(module, name, args)
      # A wrong-typed conn must never SUCCEED either (total heads that run the
      # body on garbage are the other half of the class).
      {:returned, module, name, arity}
    rescue
      e ->
        {blamed, stacktrace} = Exception.blame(:error, e, __STACKTRACE__)
        formatted = Exception.format(:error, blamed, stacktrace)

        guarded? =
          is_exception(e, ArgumentError) and
            String.starts_with?(Exception.message(e), @guard_message_prefix)

        cond do
          not guarded? ->
            {:wrong_exception, module, name, arity, e.__struct__}

          String.contains?(formatted, @sentinel_marker) ->
            {:echoed_sentinel, module, name, arity}

          true ->
            nil
        end
    end
  end
end
