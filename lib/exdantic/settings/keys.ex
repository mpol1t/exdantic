defmodule Exdantic.Settings.Keys do
  @moduledoc false

  @spec path_to_env_key([atom()], String.t(), String.t()) :: String.t()
  def path_to_env_key(path, prefix, delimiter) when is_list(path) do
    prefix <> Enum.map_join(path, delimiter, &segment_to_env/1)
  end

  @spec candidate_keys(atom(), Exdantic.FieldMeta.t(), String.t(), String.t()) :: [String.t()]
  def candidate_keys(field_name, field_meta, prefix, delimiter) do
    default_key = path_to_env_key([field_name], prefix, delimiter)

    case field_meta.extra do
      %{"env" => override} when is_binary(override) and override != "" ->
        [override, default_key]

      _ ->
        [default_key]
    end
  end

  @spec segment_to_env(atom()) :: String.t()
  def segment_to_env(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.upcase()
  end
end
