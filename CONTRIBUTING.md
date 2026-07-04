# Contributing to Arcadic

Thank you for your interest in contributing to Arcadic!

## Prerequisites

- **Elixir** 1.15+ and **Erlang/OTP** 26+
- **ArcadeDB** (for integration tests) — e.g. `docker run -p 2480:2480 \
  -e JAVA_OPTS="-Darcadedb.server.rootPassword=playwithdata" arcadedata/arcadedb:latest`

## Getting Started

```bash
git clone https://github.com/baselabs/arcadic.git
cd arcadic
mix deps.get
mix test
```

## Development Workflow

1. Create a feature branch from `main`.
2. Make your changes with clear, descriptive commit messages.
3. Ensure all checks pass before opening a PR:

```bash
mix format                        # Format code
mix credo --strict                # Lint
mix compile --warnings-as-errors  # Zero warnings
mix test                          # Run tests
mix dialyzer                      # Type checking
```

4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open a Pull Request against `main`.

## Code Style

- Use `mix format` — `.formatter.exs` holds the config.
- Add `@moduledoc` and `@doc` to public modules and functions.
- Read `AGENTS.md` before changing transport, error, or parameterization code —
  its Critical Rules are binding.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
