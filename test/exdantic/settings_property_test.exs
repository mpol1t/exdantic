defmodule Exdantic.SettingsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Exdantic.Settings
  alias Exdantic.Settings.Env
  alias Exdantic.Settings.Keys

  defmodule PrecedenceSchema do
    use Exdantic

    schema do
      field(:port, :integer, default: 5000)
    end
  end

  defmodule NestedDbSchema do
    use Exdantic

    schema do
      field(:host, :string, required: true)
      field(:pool_size, :integer, required: true)
    end
  end

  defmodule NestedRootSchema do
    use Exdantic

    schema do
      field(:database, NestedDbSchema, required: true)
    end
  end

  defmodule IntSchema do
    use Exdantic

    schema do
      field(:value, :integer, required: true)
    end
  end

  defmodule FloatSchema do
    use Exdantic

    schema do
      field(:value, :float, required: true)
    end
  end

  defmodule BoolSchema do
    use Exdantic

    schema do
      field(:value, :boolean, required: true)
    end
  end

  defmodule ArraySchema do
    use Exdantic

    schema do
      field(:items, {:array, :integer}, required: true)
    end
  end

  defmodule DynamicMapSchema do
    use Exdantic

    schema do
      field(:metadata, {:map, {:string, :integer}}, required: true)
    end
  end

  defmodule OverrideWinsSchema do
    use Exdantic

    schema do
      field(:foo, :integer, required: true, extra: %{"env" => "FOO_OVERRIDE"})
    end
  end

  defmodule StringDefaultSchema do
    use Exdantic

    schema do
      field(:value, :string, default: "fallback")
    end
  end

  defmodule IntDefaultSchema do
    use Exdantic

    schema do
      field(:value, :integer, default: 42)
    end
  end

  defmodule BoolDefaultSchema do
    use Exdantic

    schema do
      field(:value, :boolean, default: true)
    end
  end

  defmodule ScalarUnionSchema do
    use Exdantic

    schema do
      field(:value, {:union, [:string, :integer, :boolean]}, required: true)
    end
  end

  defmodule StructuredUnionSchema do
    use Exdantic

    schema do
      field(:value, {:union, [:string, {:array, :integer}]}, required: true)
    end
  end

  property "precedence is input > env > defaults" do
    check all(
            env_choice <- one_of([constant(:none), integer(0..65_535)]),
            input_choice <- one_of([constant(:none), integer(0..65_535)])
          ) do
      env =
        case env_choice do
          :none -> %{}
          n -> %{"PORT" => Integer.to_string(n)}
        end

      input =
        case input_choice do
          :none -> %{}
          n -> %{port: n}
        end

      assert {:ok, result} = Settings.load(PrecedenceSchema, env: env, input: input)

      expected =
        case {input_choice, env_choice} do
          {n, _} when is_integer(n) -> n
          {:none, n} when is_integer(n) -> n
          {:none, :none} -> 5000
        end

      assert result.port == expected
    end
  end

  property "env key derivation is deterministic for snake_case paths" do
    segment_pool = [:db_url, :pool_size, :api_key, :user_name, :max_retries, :service_port]

    check all(
            path <- list_of(member_of(segment_pool), min_length: 1, max_length: 3),
            prefix <- member_of(["", "APP_", "SERVICE_"]),
            delimiter <- member_of(["__", "_", "___"])
          ) do
      expected =
        prefix <>
          Enum.map_join(path, delimiter, &(&1 |> Atom.to_string() |> String.upcase()))

      assert Keys.path_to_env_key(path, prefix, delimiter) == expected
    end
  end

  property "nested merge gives exploded values precedence over top-level JSON" do
    check all(
            host <- string(:alphanumeric, min_length: 1, max_length: 12),
            pool <- integer(1..1000)
          ) do
      json_pool = max(pool - 1, 1)

      env = %{
        "APP_DATABASE" => ~s({"host":"#{host}","pool_size":#{json_pool}}),
        "APP_DATABASE__POOL_SIZE" => Integer.to_string(pool)
      }

      assert {:ok, result} = Settings.load(NestedRootSchema, env: env, env_prefix: "APP_")
      assert result.database.host == host
      assert result.database.pool_size == pool
    end
  end

  property "integer env decoding round-trips stringified integers" do
    check all(value <- integer(-1_000_000..1_000_000)) do
      assert {:ok, result} = Settings.load(IntSchema, env: %{"VALUE" => Integer.to_string(value)})
      assert result.value == value
    end
  end

  property "float env decoding parses finite decimal strings" do
    check all(num <- integer(-1_000_000..1_000_000), den <- integer(1..10_000)) do
      value = num / den
      float_string = :erlang.float_to_binary(value, [:compact, decimals: 10])

      assert {:ok, result} = Settings.load(FloatSchema, env: %{"VALUE" => float_string})
      assert abs(result.value - value) < 1.0e-9
    end
  end

  property "boolean env decoding accepts only true/false and optional 1/0 tokens" do
    check all(
            {token, expected} <-
              member_of([{"true", true}, {"FALSE", false}, {"1", true}, {"0", false}])
          ) do
      assert {:ok, result} = Settings.load(BoolSchema, env: %{"VALUE" => token})
      assert result.value == expected
    end
  end

  property "invalid boolean tokens return env_cast errors" do
    invalid_tokens = ["yes", "no", "on", "off", "t", "f", "truthy", ""]

    check all(token <- member_of(invalid_tokens)) do
      assert {:error, errors} =
               Settings.load(BoolSchema, env: %{"VALUE" => token}, ignore_empty: false)

      assert Enum.any?(errors, &(&1.code == :env_cast))
    end
  end

  property "structured JSON env values decode successfully for arrays" do
    check all(values <- list_of(integer(-100..100), max_length: 15)) do
      encoded = Jason.encode!(values)
      assert {:ok, result} = Settings.load(ArraySchema, env: %{"ITEMS" => encoded})
      assert result.items == values
    end
  end

  property "invalid structured JSON returns env_json errors" do
    invalid_json_values = ["{", "[1,", "{\"k\":", "not-json", "]", "{\"a\":1"]

    check all(raw <- member_of(invalid_json_values)) do
      assert {:error, errors} = Settings.load(ArraySchema, env: %{"ITEMS" => raw})
      assert Enum.any?(errors, &(&1.code == :env_json))
    end
  end

  property "dynamic map keys remain strings (no atomization of arbitrary JSON keys)" do
    key_gen = string(:alphanumeric, min_length: 1, max_length: 8)
    val_gen = integer(0..1000)

    check all(payload <- map_of(key_gen, val_gen, min_length: 1, max_length: 8)) do
      encoded = Jason.encode!(payload)
      assert {:ok, result} = Settings.load(DynamicMapSchema, env: %{"METADATA" => encoded})
      assert Map.keys(result.metadata) |> Enum.all?(&is_binary/1)
    end
  end

  property "case-insensitive env normalization is idempotent and uppercases keys" do
    check all(
            base_env <-
              map_of(
                string(:alphanumeric, min_length: 1, max_length: 8),
                string(:printable, max_length: 8),
                max_length: 40
              )
          ) do
      env =
        Enum.into(base_env, %{}, fn {k, v} ->
          transformed =
            if rem(byte_size(k), 2) == 0 do
              String.downcase(k)
            else
              String.upcase(k)
            end

          {transformed, v}
        end)

      case Env.normalize_env_map(env, false) do
        {:ok, normalized} ->
          assert Enum.all?(Map.keys(normalized), fn key -> key == String.upcase(key) end)
          assert {:ok, normalized_again} = Env.normalize_env_map(normalized, false)
          assert normalized_again == normalized
          assert map_size(normalized) <= map_size(env)

        {:error, errors} ->
          assert Enum.any?(errors, &(&1.code == :env_key_conflict))
      end
    end
  end

  property "field env override is absolute and wins over derived key regardless of prefix" do
    check all(
            override_value <- integer(-10_000..10_000),
            derived_value <- integer(-10_000..10_000),
            prefix <- member_of(["", "APP_", "SERVICE_", "X_"])
          ) do
      env = %{
        "FOO_OVERRIDE" => Integer.to_string(override_value),
        "#{prefix}FOO" => Integer.to_string(derived_value)
      }

      assert {:ok, result} = Settings.load(OverrideWinsSchema, env: env, env_prefix: prefix)
      assert result.foo == override_value
    end
  end

  property "ignore_empty controls whether empty string env is treated as absent for scalars" do
    check all(schema_kind <- member_of([:string, :integer, :boolean])) do
      {schema, default} =
        case schema_kind do
          :string -> {StringDefaultSchema, "fallback"}
          :integer -> {IntDefaultSchema, 42}
          :boolean -> {BoolDefaultSchema, true}
        end

      assert {:ok, absent_result} =
               Settings.load(schema, env: %{"VALUE" => ""}, ignore_empty: true)

      assert absent_result.value == default

      case Settings.load(schema, env: %{"VALUE" => ""}, ignore_empty: false) do
        {:ok, present_result} ->
          assert schema_kind == :string
          assert present_result.value == ""

        {:error, errors} ->
          assert schema_kind in [:integer, :boolean]
          assert Enum.any?(errors, &(&1.code == :env_cast))
      end
    end
  end

  test "exploded env addressing into arrays is ignored (arrays require JSON)" do
    assert {:error, errors} =
             Settings.load(ArraySchema,
               env: %{"APP_ITEMS__0" => "123"},
               env_prefix: "APP_",
               env_nested_delimiter: "__"
             )

    assert Enum.any?(errors, &(&1.code == :required))
  end

  property "no atom leak approximation: settings modules never call String.to_atom/1" do
    settings_files = [
      "lib/exdantic/settings.ex",
      "lib/exdantic/settings/decode.ex",
      "lib/exdantic/settings/deep_merge.ex",
      "lib/exdantic/settings/env.ex",
      "lib/exdantic/settings/keys.ex",
      "lib/exdantic/settings/loader.ex",
      "lib/exdantic/settings/normalize_keys.ex"
    ]

    check all(_ <- constant(:ok)) do
      for path <- settings_files do
        content = File.read!(path)
        refute String.contains?(content, "String.to_atom(")
      end
    end
  end

  property "union decoding is deterministic for scalar-like env strings (no union-level scalar coercion)" do
    check all(token <- member_of(["0", "01", "true", "FALSE", "123.45", "hello"])) do
      assert {:ok, result} = Settings.load(ScalarUnionSchema, env: %{"VALUE" => token})
      assert result.value == token
    end
  end

  property "structured unions decode JSON only for JSON-like input and fail with env_json on invalid JSON-like input" do
    check all(values <- list_of(integer(-100..100), max_length: 8)) do
      payload = Jason.encode!(values)
      assert {:ok, result} = Settings.load(StructuredUnionSchema, env: %{"VALUE" => payload})
      assert result.value == values

      assert {:error, errors} = Settings.load(StructuredUnionSchema, env: %{"VALUE" => "[1,"})
      assert Enum.any?(errors, &(&1.code == :env_json))
    end
  end
end
