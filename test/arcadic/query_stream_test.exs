defmodule Arcadic.QueryStreamTest do
  use ExUnit.Case, async: true
  alias Arcadic.{Conn, Transport.Bolt}
  alias Boltx.Types.{Duration, Point}

  defp bolt_conn(db \\ "mydb"),
    do:
      Conn.new("http://h:2480", db,
        auth: {"u", "p"},
        transport: Bolt,
        transport_options: [bolt: :ignored]
      )

  describe "Bolt.run_extra/1 and format_params/1" do
    test "run_extra/1 carries the conn database as the db extra" do
      assert Bolt.run_extra(bolt_conn("mydb")) == %{db: "mydb"}
    end

    test "format_params/1 is identity for scalar/map/list params" do
      params = %{"k" => "v", "n" => 5, "l" => [1, 2], "m" => %{"a" => 1}}
      assert Bolt.format_params(params) == params
    end

    test "format_params/1 handles the empty map" do
      assert Bolt.format_params(%{}) == %{}
    end

    test "format_params/1 formats Duration/Point params via boltx (not passthrough)" do
      dur = %Duration{days: 1, hours: 2, minutes: 3, seconds: 4}
      point = Point.create(:cartesian, 10, 20.0)

      {:ok, expected_dur} = Duration.format_param(dur)
      {:ok, expected_point} = Point.format_param(point)

      # The formatted value must differ from the raw struct, else this asserts nothing.
      refute expected_dur == dur
      refute expected_point == point

      assert Bolt.format_params(%{"d" => dur, "p" => point}) == %{
               "d" => expected_dur,
               "p" => expected_point
             }
    end
  end
end
