defmodule Arcadic.MigrationRegistry do
  @moduledoc """
  Declares an ordered list of migration modules.

      defmodule MyApp.Migrations do
        use Arcadic.MigrationRegistry
        migrations [MyApp.Migrations.V1, MyApp.Migrations.V2]
      end
  """

  @doc "The ordered list of migration modules."
  @callback migrations() :: [module()]

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour Arcadic.MigrationRegistry
      import Arcadic.MigrationRegistry, only: [migrations: 1]
    end
  end

  @doc "Declare the ordered migration modules."
  defmacro migrations(modules) do
    quote do
      @impl Arcadic.MigrationRegistry
      def migrations, do: unquote(modules)
    end
  end
end
