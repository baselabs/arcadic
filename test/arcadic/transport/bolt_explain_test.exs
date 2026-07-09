defmodule Arcadic.Transport.BoltExplainTest do
  use ExUnit.Case, async: true

  @moduletag :bolt

  test "Bolt transport implements the explain/3 optional callback" do
    # function_exported? is vacuously false unless the target module is loaded (S6 T1 lesson).
    assert Code.ensure_loaded?(Arcadic.Transport.Bolt)
    assert function_exported?(Arcadic.Transport.Bolt, :explain, 3)
  end

  test "moduledoc shows the setup/1 transport_options shape, not the streaming-broken [bolt: …]-only form" do
    {:docs_v1, _, _, _, %{"en" => doc}, _, _} = Code.fetch_docs(Arcadic.Transport.Bolt)
    assert doc =~ "setup/1"
    refute doc =~ "transport_options: [bolt: conn_ref]"
  end
end
