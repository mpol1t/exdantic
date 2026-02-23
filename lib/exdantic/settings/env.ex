defmodule Exdantic.Settings.Env do
  @moduledoc false

  alias Exdantic.Error

  @spec normalize_env_map(map(), boolean()) :: {:ok, map()} | {:error, [Error.t()]}
  def normalize_env_map(env, case_sensitive) when is_map(env) do
    if case_sensitive do
      {:ok, stringify_keys(env)}
    else
      normalize_case_insensitive(env)
    end
  end

  defp stringify_keys(env) do
    env
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  defp normalize_case_insensitive(env) do
    {normalized, collisions} =
      Enum.reduce(env, {%{}, %{}}, fn {k, v}, {acc, seen} ->
        key = to_string(k)
        up = String.upcase(key)

        if Map.has_key?(seen, up) and Map.fetch!(seen, up) != key do
          {acc, Map.put(seen, up, :collision)}
        else
          {Map.put(acc, up, v), Map.put_new(seen, up, key)}
        end
      end)

    collision_keys =
      collisions
      |> Enum.filter(fn {_k, v} -> v == :collision end)
      |> Enum.map(fn {k, _} -> k end)

    if collision_keys == [] do
      {:ok, normalized}
    else
      message =
        "case-insensitive env key conflict for keys: #{inspect(Enum.sort(collision_keys))}"

      {:error, [Error.new([], :env_key_conflict, message)]}
    end
  end

  @spec lookup(map(), String.t(), keyword()) :: {:ok, term()} | :not_found
  def lookup(env_map, key, opts) do
    key_to_lookup = lookup_key(key, opts)
    ignore_empty = Keyword.get(opts, :ignore_empty, false)

    case Map.fetch(env_map, key_to_lookup) do
      {:ok, ""} ->
        if ignore_empty, do: :not_found, else: {:ok, ""}

      {:ok, value} ->
        {:ok, value}

      :error ->
        :not_found
    end
  end

  @spec lookup_key(String.t(), keyword()) :: String.t()
  def lookup_key(key, opts) do
    if Keyword.get(opts, :case_sensitive, false), do: key, else: String.upcase(key)
  end
end
