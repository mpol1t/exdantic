defmodule Exdantic.Settings.NormalizeKeys do
  @moduledoc false

  @spec normalize_for_schema(module(), map()) :: map()
  def normalize_for_schema(schema_module, input) when is_map(input) do
    fields = schema_module.__schema__(:fields)
    normalize_known_map(input, fields)
  end

  defp normalize_known_map(map_value, fields) when is_map(map_value) and is_list(fields) do
    {normalized_known, consumed_keys} =
      Enum.reduce(fields, {%{}, MapSet.new()}, fn {name, meta}, {acc, consumed} ->
        atom_present? = Map.has_key?(map_value, name)
        string_key = Atom.to_string(name)
        string_present? = Map.has_key?(map_value, string_key)

        cond do
          atom_present? ->
            value = Map.fetch!(map_value, name)
            norm_value = normalize_by_type(meta.type, value)

            consumed =
              consumed
              |> MapSet.put(name)
              |> maybe_put(string_present?, string_key)

            {Map.put(acc, name, norm_value), consumed}

          string_present? ->
            value = Map.fetch!(map_value, string_key)
            norm_value = normalize_by_type(meta.type, value)
            {Map.put(acc, name, norm_value), MapSet.put(consumed, string_key)}

          true ->
            {acc, consumed}
        end
      end)

    unknown =
      map_value
      |> Enum.reject(fn {k, _v} -> MapSet.member?(consumed_keys, k) end)
      |> Map.new()

    Map.merge(unknown, normalized_known)
  end

  defp normalize_by_type({:ref, schema}, value) when is_map(value) and is_atom(schema) do
    if schema_module?(schema), do: normalize_for_schema(schema, value), else: value
  end

  defp normalize_by_type(schema_module, value) when is_map(value) and is_atom(schema_module) do
    cond do
      schema_module?(schema_module) ->
        normalize_for_schema(schema_module, value)

      custom_type_module?(schema_module) ->
        normalize_by_type(schema_module.type_definition(), value)

      true ->
        value
    end
  end

  defp normalize_by_type({:object, fields, _}, value) when is_map(value) and is_map(fields) do
    field_list =
      fields
      |> Enum.map(fn {name, type} ->
        {name, %Exdantic.FieldMeta{name: name, type: type, required: false}}
      end)

    normalize_known_map(value, field_list)
  end

  defp normalize_by_type({:array, inner, _}, values) when is_list(values) do
    Enum.map(values, &normalize_by_type(inner, &1))
  end

  defp normalize_by_type({:map, {_k_type, v_type}, _}, values) when is_map(values) do
    Enum.into(values, %{}, fn {k, v} -> {k, normalize_map_value(v_type, v)} end)
  end

  # Keep unions unchanged in v1.
  defp normalize_by_type({:union, _types, _}, value), do: value
  defp normalize_by_type(_type, value), do: value

  defp normalize_map_value(type, value) do
    cond do
      is_map(value) and schema_like_type?(type) ->
        normalize_by_type(type, value)

      is_list(value) and match?({:array, _, _}, type) ->
        normalize_by_type(type, value)

      true ->
        value
    end
  end

  defp schema_like_type?({:ref, _}), do: true
  defp schema_like_type?({:object, _, _}), do: true

  defp schema_like_type?(type) when is_atom(type) do
    schema_module?(type) or custom_type_module?(type)
  end

  defp schema_like_type?(_), do: false

  defp maybe_put(set, true, key), do: MapSet.put(set, key)
  defp maybe_put(set, false, _key), do: set

  defp schema_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1)
  end

  defp custom_type_module?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :type_definition, 0)
  end
end
