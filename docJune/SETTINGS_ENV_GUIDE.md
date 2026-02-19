# Exdantic Settings Guide (Env-First Configuration)

This guide documents the `Exdantic.Settings` API and behavior for loading application configuration from environment variables.

## Overview

`Exdantic.Settings` is a runtime loader layer on top of Exdantic schema validation. It:

- Collects env values using schema fields as the source of truth
- Decodes env strings to typed values (with strict, predictable rules)
- Merges env-derived values with explicit input overrides
- Normalizes known schema keys to avoid strict-mode false extras
- Delegates final validation to Exdantic validators

Public API:

- `Exdantic.Settings.load(schema_module, opts \\ [])`
- `Exdantic.Settings.load!(schema_module, opts \\ [])`
- `Exdantic.Settings.from_system_env(schema_module, opts \\ [])`

Return shape:

- `{:ok, result}` on success
- `{:error, [Exdantic.Error.t()]}` on failure
- `load!/2` raises `Exdantic.ValidationError` on failure

## Quick Start

```elixir
defmodule AppConfig do
  use Exdantic

  schema do
    field :port, :integer, default: 4000
    field :debug, :boolean, default: false
    field :database, DatabaseConfig, required: true
    field :db_url, :string, required: true, extra: %{"env" => "DATABASE_URL"}
  end
end

defmodule DatabaseConfig do
  use Exdantic

  schema do
    field :host, :string, required: true
    field :pool_size, :integer, default: 10
  end
end
```

Load with injected env map (test-friendly):

```elixir
{:ok, config} =
  Exdantic.Settings.load(AppConfig,
    env: %{
      "APP_PORT" => "8080",
      "APP_DATABASE" => ~s({"host":"localhost","pool_size":5}),
      "APP_DATABASE__POOL_SIZE" => "12",
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/app_db"
    },
    env_prefix: "APP_"
  )
```

Load from process environment:

```elixir
{:ok, config} =
  Exdantic.Settings.from_system_env(AppConfig,
    env_prefix: "APP_",
    env_nested_delimiter: "__"
  )
```

## Options

- `input: map()` explicit values merged over env-derived values
- `env: map()` custom env source (defaults to `System.get_env/0`)
- `env_prefix: String.t()` default `""`
- `env_nested_delimiter: String.t()` default `"__"`
- `case_sensitive: boolean()` default `false`
- `ignore_empty: boolean()` default `false`
- `allow_atoms: false | :existing` default `false`
- `bool_numeric: boolean()` default `true`

## Key Derivation and Matching

### Default env key derivation

- Field atom segments are converted via:
  - `Atom.to_string/1`
  - `String.upcase/1`
- Nested segments are joined by `env_nested_delimiter` (default `"__"`)
- `env_prefix` is prepended as-is

Examples:

- `:db_url` -> `"DB_URL"`
- `[:database, :pool_size]` -> `"DATABASE__POOL_SIZE"`
- with `env_prefix: "APP_"` -> `"APP_DATABASE__POOL_SIZE"`

### Field-level override

Set per-field override with extra metadata:

```elixir
field :db_url, :string, extra: %{"env" => "DATABASE_URL"}
```

Behavior:

- Override is absolute (prefix is not applied)
- Candidate lookup order is:
  1. override key
  2. derived key
- If both are present, override wins

### Case sensitivity

- Default is case-insensitive (`case_sensitive: false`)
- Loader normalizes env keys to uppercase once for matching
- If normalization causes collisions (for example both `"app_port"` and `"APP_PORT"`), loader returns:
  - `%Exdantic.Error{code: :env_key_conflict, path: []}`

## Merge and Precedence Rules

Final precedence:

1. explicit `input`
2. env-derived values
3. schema defaults
4. required field errors from validator

Nested merge behavior for same field:

- Top-level env JSON is decoded first
- Exploded nested env keys are deep-merged over top-level JSON
- On scalar conflict, exploded value wins

Example:

- `APP_DATABASE='{"pool_size":5,"host":"a"}'`
- `APP_DATABASE__POOL_SIZE=10`
- Result: `%{database: %{host: "a", pool_size: 10}}`

## Decoding Rules

## Scalars

- `:string` -> raw string
- `:integer` -> `Integer.parse/1` with full consume required
- `:float` -> `Float.parse/1` with full consume required
- `:boolean` -> accepts only:
  - `"true"` / `"false"` (case-insensitive)
  - and `"1"` / `"0"` when `bool_numeric: true`
- `:atom`:
  - default: disabled (`:env_cast` error)
  - `allow_atoms: :existing`: uses `String.to_existing_atom/1`
- Unknown scalar-like/custom scalar values:
  - passed through raw string and validated by Exdantic

## Structured types (JSON-only)

Structured values must be valid JSON from env strings:

- arrays (`{:array, ...}`)
- maps/objects
- nested schema refs

Invalid JSON returns:

- `%Exdantic.Error{code: :env_json, path: ...}`

No CSV parsing is performed in v1.

## Unions

Conservative rule:

- If env string starts with `{` or `[` and union includes any structured member:
  - JSON decode is attempted
  - decode failure is `:env_json`
- Otherwise:
  - raw string is passed to validator
  - no union-level scalar probing/coercion is performed

## Exploded Nested Variables

Exploded addressing uses `env_nested_delimiter`:

- Example: `APP_DATABASE__HOST=localhost`

Supported:

- nested object/schema fields

Not supported in v1:

- exploded addressing into arrays (for example `APP_ITEMS__0=...`)
- Arrays must come from JSON env value (for example `APP_ITEMS='[1,2,3]'`)

## Empty String Behavior

- `ignore_empty: false` (default):
  - empty string is treated as provided input value
- `ignore_empty: true`:
  - empty-string env entries are treated as not provided

## Error Codes

Settings-specific pre-validation errors:

- `:env_cast` for scalar decode failures
- `:env_json` for structured JSON decode failures
- `:env_key_conflict` for case-insensitive key collisions

Validation errors from Exdantic (for example `:required`, `:type`, constraint errors) are returned normally after loader decoding/merge.

## Testing Patterns

Use `env: %{...}` in tests. Do not mutate OS environment.

Example:

```elixir
assert {:ok, cfg} =
  Exdantic.Settings.load(AppConfig,
    env: %{"APP_PORT" => "9000"},
    env_prefix: "APP_"
  )

assert cfg.port == 9000
```

## Recommended Client Convention

Prefer one top-level app config schema:

- Define nested schemas for subsystems
- Use one root schema (for example `AppConfig`)
- Load once at app boot via `Exdantic.Settings.from_system_env/2`
- Inject the validated config downstream

This keeps configuration centralized, typed, and validated consistently.
