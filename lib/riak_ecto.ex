defmodule Riak.Ecto do
  @moduledoc """
  Adapter module for Riak, using a map bucket_type to store models.
  It uses `riakc` for communicating with the database and manages
  a connection pool using `poolboy`.
  ## Features
  * WIP
  """

  @behaviour Ecto.Adapter

  alias Riak.Ecto.NormalizedQuery
  alias Riak.Ecto.Connection

  ## Adapter

  @doc false
  defmacro __before_compile__(env) do
    module = env.module
    config = Module.get_attribute(module, :config)
    adapter = Keyword.get(config, :pool, Riak.Pool.Poolboy)

    quote do
      defmodule Pool do
        use Riak.Pool, name: __MODULE__, adapter: unquote(adapter)

#        def log(return, queue_time, query_time, fun, args) do
#          Riak.Ecto.log(unquote(module), return, queue_time, query_time, fun, args)
#        end
      end

      def __riak_pool__, do: unquote(module).Pool
    end
  end

  @doc false
  def application do
    Riak.Pool.Poolboy
  end

  @doc false
  def start_link(repo, opts) do
    {:ok, _} = Application.ensure_all_started(:riak_ecto)

    repo.__riak_pool__.start_link(opts)
  end

  def child_spec(repo, opts) do
    Supervisor.Spec.worker(__MODULE__, [repo,opts], [])
  end

  @doc false
  def autogenerate(:binary_id), do: Riak.Ecto.Utils.unique_id_62
  def autogenerate(:embed_id), do: Riak.Ecto.Utils.unique_id_62
  def autogenerate(:id) do
    raise ArgumentError,
      "Riak adapter does not support :id field type in struct."
  end

  @doc false
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:datetime, type), do: [&datetime_decode/1, type]
  def loaders(:float, type), do: [&float_decode/1, type]
  def loaders(:integer, type), do: [&integer_decode/1, type]
  def loaders({:array, _} = type, _), do: [&load_array(type, &1)]
  def loaders({:embed, %Ecto.Embedded{cardinality: :many}} = type, _), do: [&load_embed(type, &1)]
  def loaders(:binary_id, type), do: [:string, type]

  def loaders(_, type), do: [type]

  defp load_embed(type, value) do
    Ecto.Type.load(type, for({_, v} <- value, into: [], do: v), fn
      {:embed, _} = type, value -> load_embed(type, value)
      type, value -> Ecto.Type.cast(type, value)
    end)
  end

  defp load_array(type, value) do
    list = value
    |> Stream.map(fn {idx, v} -> {String.to_integer(idx), v} end)
    |> Enum.into([])
    |> Enum.sort(fn {idx1, _}, {idx2, _} -> idx1 < idx2 end)
    |> Enum.map(fn {_, v} -> v end)

    Ecto.Type.cast(type, list)
  end

  defp date_decode(nil), do: {:ok, nil}
  defp date_decode(iso8601) do
    case Ecto.Date.cast(iso8601) do
      {:ok, date} -> {:ok, {date.year, date.month, date.day}}
      :error      -> :error
    end
  end

  defp datetime_decode(nil), do: {:ok, nil}
  defp datetime_decode(iso8601) do
    case Ecto.DateTime.cast(iso8601) do
      {:ok, datetime} -> {:ok, {{datetime.year, datetime.month, datetime.day}, {datetime.hour, datetime.min, datetime.sec, datetime.usec}}}
      :error          -> :error
    end
  end

  defp float_decode(nil), do: {:ok, nil}
  defp float_decode(string) do
    case Float.parse(string) do
      {value, ""} -> {:ok, value}
      _           -> :error
    end
  end

  defp integer_decode(nil), do: {:ok, nil}
  defp integer_decode(string) do
    case Integer.parse(string) do
      {value, ""} -> {:ok, value}
      _           -> :error
    end
  end

  @doc false

  def dumpers(:integer, type), do: [type, &register_encode/1]
  def dumpers(:float, type), do: [type, &register_encode/1]
  def dumpers(:date, type), do: [type, &register_encode/1]
  def dumpers(:datetime, type), do: [type, &register_encode/1]

  def dumpers({:embed, %Ecto.Embedded{cardinality: :many}} = type, _), do: [&dump_embed(type, &1)]
  def dumpers({:array, _} = type, _), do: [&dump_list(type, &1)]
  def dumpers(:binary_id, type), do: [type, :string]
  def dumpers(_, type), do: [type]

  defp dump_embed({:embed, %Ecto.Embedded{cardinality: :many, related: struct}} = type, value) do
    [pk] = struct.__schema__(:primary_key)
    Ecto.Type.dump(type, value, fn
      {:embed, %Ecto.Embedded{cardinality: :many}} = type, value -> dump_embed(type, value)
      _type, value -> {:ok, value}
    end)
    |> case do
         {:ok, list} ->
           {:ok, for(el <- list, into: %{}, do: {Map.fetch!(el, pk), el})}
         other -> other
       end
  end

  defp dump_list({:array, _}, value) when is_list(value) do
    map = value
    |> Stream.with_index
    |> Stream.map(fn {idx, v} -> {to_string(v), to_string(idx)} end)
    |> Enum.into(%{})

    {:ok, map}
  end

  defp register_encode({_year, _month, _day} = date) do
    value = date
    |> Ecto.Date.from_erl
    |> Ecto.Date.to_iso8601

    {:ok, value}
  end

  defp register_encode({{year, month, day}, {hour, min, sec}}) do
    value = {{year, month, day}, {hour, min, sec}}
    |> Ecto.DateTime.from_erl
    |> Ecto.DateTime.to_iso8601
    |> Kernel.<>("Z")
    {:ok, value}
  end
  defp register_encode({{year, month, day}, {hour, min, sec, _}}) do
    register_encode({{year, month, day}, {hour, min, sec}})
  end
  defp register_encode(term), do: {:ok, to_string(term)}

  @doc false
  def stop(repo, _pid, _timeout \\ 5_000) do
    repo.__riak_pool__.stop
  end

  @doc false
  def prepare(function, query) do
    {:nocache, {function, query}}
  end

  @doc false
  def execute(repo, _meta, {_, {:all, query}}, params, process, opts) do
    norm_query = NormalizedQuery.all(query, params)
    {rows, count} =
      Connection.all(repo.__riak_pool__, norm_query, opts)
      |> Enum.map_reduce(0, &{process_document(&1, norm_query, process), &2 + 1})
    {count, rows}
  end

  @doc false
  def insert(repo, %{source: {prefix, source}}, fields, _returning, options) do
    Connection.insert(repo.__riak_pool__, prefix, source, fields, options)
  end

  def update(_repo, %{context: nil} = meta, _fields, _filter, _, _options) do
    raise ArgumentError,
      "No causal context in #{inspect meta.struct}. " <>
      "Get the model by id before trying to update it."
  end

  def update(_repo, meta, _fields, _filter, [_|_] = returning, _options) do
    raise ArgumentError,
      "Riak adapter does not support :read_after_writes. " <>
      "The following fields in #{inspect meta.struct} are tagged as such: #{inspect returning}"
  end

  def update(repo, %{source: {prefix, source}, context: context}, fields, [id: id], _returning, options) do
    Connection.update(repo.__riak_pool__, prefix, source, context, id, fields, options)
  end

  def update(_repo, _meta, _fields, [_ | _], _, _options) do
    raise ArgumentError,
      "Riak adapter only supports updating by id."
  end

  def delete(repo, %{source: {prefix, source}}, [id: id], options) do
    Connection.delete(repo.__riak_pool__, prefix, source, id, options)
  end

  def delete(_repo, _meta, [_ | _], _options) do
    raise ArgumentError,
      "Riak adapter only supports deleting by id."
  end

  @doc false
  def delete(_repo, meta, _filter, {key, :id, _}, _opts) do
    raise ArgumentError,
      "Riak adapter does not support :id field type in models. " <>
      "The #{inspect key} field in #{inspect meta.model} is tagged as such."
  end

  def delete(repo, meta, filter, {pk, :binary_id, _value}, opts) do
    normalized = NormalizedQuery.delete(meta.source, meta.context, filter, pk)
    Connection.delete(repo.__riak_pool__, normalized, opts)
  end

  def delete(repo, meta, [id: pk] = filter, nil, opts) do
    normalized = NormalizedQuery.delete(meta.source, meta.context, filter, pk)
    Connection.delete(repo.__riak_pool__, normalized, opts)
  end

  def insert_all(_, _, _, _, _, _) do
    raise ArgumentError,
      "Riak adapter does not support insert_all."
  end

  def process_document({context, document}, %{projection: projection, pk: _pk}, process) do
    Enum.map(projection, &process.(&1, document, context))
  end

  @doc false
  def log(repo, :ok, queue_time, query_time, fun, args) do
    log(repo, {:ok, nil}, queue_time, query_time, fun, args)
  end
  def log(repo, return, queue_time, query_time, fun, args) do
    entry =
      %Ecto.LogEntry{query: &format_log(&1, fun, args), params: [],
                     result: return, query_time: query_time, queue_time: queue_time}
    repo.log(entry)
  end

  defp format_log(_entry, :run_command, [command, _opts]) do
    ["COMMAND " | inspect(command)]
  end
  defp format_log(_entry, :fetch_type, [bucket_type, bucket, id, _opts]) do
    ["FETCH_TYPE", format_part("bucket_type", bucket_type), format_part("bucket", bucket), format_part("id", id)]
  end
  defp format_log(_entry, :update_type, [bucket_type, bucket, id, _opts]) do
    ["UPDATE_TYPE", format_part("bucket_type", bucket_type), format_part("bucket", bucket), format_part("id", id)]
  end
  defp format_log(_entry, :search, [index, bucket, filter, _opts]) do
    ["SEARCH", format_part("index", index), format_part("bucket", bucket), format_part("filter", filter)]
  end
  defp format_log(_entry, :delete, [bucket_type, bucket, filter, _opts]) do
    ["DELETE", format_part("bucket_type", bucket_type), format_part("bucket", bucket), format_part("filter", filter),
     format_part("many", false)]
  end

  defp format_part(name, value) do
    [" ", name, "=" | inspect(value)]
  end
end
