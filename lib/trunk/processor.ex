defmodule Trunk.Processor do
  @moduledoc false

  alias Trunk.State

  def store(%{async: true} = state) do
    process_async(state, fn(version, map, state) ->
          with {:ok, map} <- get_version_transform(map, version, state),
               {:ok, map} <- transform_version(map, version, update_state(state, version, map)),
               {:ok, map} <- postprocess_version(map, version, update_state(state, version, map)),
               {:ok, map} <- get_version_storage_dir(map, version, update_state(state, version, map)),
               {:ok, map} <- get_version_filename(map, version, update_state(state, version, map)),
               {:ok, map} <- get_version_storage_opts(map, version, update_state(state, version, map)) do
           save_version(map, version, update_state(state, version, map))
         end
               end)
  end
  def store(%{async: false} = state) do
    with {:ok, state} <- map_versions(state, &get_version_transform/3),
         {:ok, state} <- map_versions(state, &transform_version/3),
         {:ok, state} <- map_versions(state, &postprocess_version/3),
         {:ok, state} <- map_versions(state, &get_version_storage_dir/3),
         {:ok, state} <- map_versions(state, &get_version_filename/3),
         {:ok, state} <- map_versions(state, &get_version_storage_opts/3) do
       map_versions(state, &save_version/3)
    end
  end

  def delete(%{async: true} = state) do
    process_async(state, fn(version, map, state) ->
      with {:ok, map} <- get_version_storage_dir(map, version, update_state(state, version, map)),
      {:ok, map} <- get_version_filename(map, version, update_state(state, version, map)) do
        delete_version(map, version, update_state(state, version, map))
      end
    end)
  end
  def delete(%{async: false} = state) do
    with {:ok, state} <- map_versions(state, &get_version_storage_dir/3),
         {:ok, state} <- map_versions(state, &get_version_filename/3) do
      map_versions(state, &delete_version/3)
    end
  end

  def process_async(%{versions: versions, version_timeout: version_timeout} = state, func) do
    tasks =
      versions
      |> Enum.map(fn({version, map}) ->
        task = Task.async(fn -> func.(version, map, state) end)
        {version, task}
      end)

    task_list = Enum.map(tasks, fn({_version, task}) -> task end)

    task_list
    |> Task.yield_many(version_timeout)
    |> Enum.map(fn({task, result}) ->
      {task, result || Task.shutdown(task, :brutal_kill)}
    end)
    |> Enum.map(fn
      {task, nil} ->
        {find_task_version(tasks, task), {:error, :timeout}}
      {task, {:ok, response}} ->
        {find_task_version(tasks, task), response}
      {task, other} ->
        {find_task_version(tasks, task), other}
    end)
    |> Enum.reduce(state, fn
      {version, {:ok, map}}, %{versions: versions} = state ->
        versions = Map.put(versions, version, map)
        %{state | versions: versions}
      {version, {:error, error}}, state ->
        State.put_error(state, version, :processing, error)
      {version, {:error, stage, error}}, state ->
        State.put_error(state, version, stage, error)
    end)
    |> ok
  end

  defp find_task_version([], _task), do: nil
  defp find_task_version([{version, task} | _tail], task), do: version
  defp find_task_version([_head | tail], task),
    do: find_task_version(tail, task)

  defp update_state(%{versions: versions} = state, version, version_map),
    do: %{state | versions: Map.put(versions, version, version_map)}

  defp map_versions(%{versions: versions} = state, func) do
    {versions, state} =
      versions
      |> Enum.map_reduce(state, fn({version, map}, state) ->
        case func.(map, version, state) do
          {:ok, version_map} ->
            {{version, version_map}, state}
          {:error, stage, reason} ->
            {{version, map}, State.put_error(state, version, stage, reason)}
        end
      end)
    ok(%{state | versions: versions})
  end

  def generate_url(%{versions: versions, storage: storage, storage_opts: storage_opts} = state, version) do
    map = versions[version]
    %{filename: filename, storage_dir: storage_dir} =
      with {:ok, map} = get_version_storage_dir(map, version, state),
           {:ok, map} = get_version_filename(map, version, state) do
        map
      end

    storage.build_uri(storage_dir, filename, storage_opts)
  end

  defp get_version_transform(version_state, version, %{module: module} = state),
    do: {:ok, Map.put(version_state, :transform, module.transform(state, version))}

  @doc false
  def transform_version(%{transform: nil} = version_state, _version, _state), do: ok(version_state)
  def transform_version(%{transform: transform} = version_state, _version, state) do
    case perform_transform(transform, state) do
      {:ok, temp_path} ->
        version_state
        |> Map.put(:temp_path, temp_path)
        |> ok
      {:error, error} ->
        {:error, :transform, error}
    end
  end

  defp postprocess_version(version_state, version, %{module: module} = state),
    do: module.postprocess(version_state, version, state)

  defp create_temp_path(%{}, {_, _, extname}),
    do: Briefly.create(extname: ".#{extname}")
  defp create_temp_path(%{extname: extname}, _),
    do: Briefly.create(extname: extname)

  defp perform_transform(transform, %{path: path}) when is_function(transform),
    do: transform.(path)
  defp perform_transform(transform, %{path: path} = state) do
    {:ok, temp_path} = create_temp_path(state, transform)
    perform_transform(transform, path, temp_path)
  end
  defp perform_transform({command, arguments, _ext}, source, destination),
    do: perform_transform(command, arguments, source, destination)
  defp perform_transform({command, arguments}, source, destination),
    do: perform_transform(command, arguments, source, destination)
  defp perform_transform(command, arguments, source, destination) do
    args = prepare_transform_arguments(source, destination, arguments)
    case System.cmd(to_string(command), args, stderr_to_stdout: true) do
      {_result, 0} -> {:ok, destination}
      {result, _} -> {:error, result}
    end
  end

  defp prepare_transform_arguments(source, destination, [_ | _] = arguments),
    do: [source | arguments] ++ [destination]
  defp prepare_transform_arguments(source, destination, arguments),
    do: prepare_transform_arguments(source, destination, String.split(arguments, " "))

  defp get_version_storage_dir(version_state, version, %{module: module} = state),
    do: {:ok, %{version_state | storage_dir: module.storage_dir(state, version)}}

  defp get_version_storage_opts(version_state, version, %{module: module} = state),
    do: {:ok, %{version_state | storage_opts: module.storage_opts(state, version)}}

  defp get_version_filename(version_state, version, %{module: module} = state),
    do: {:ok, %{version_state | filename: module.filename(state, version)}}

  defp save_version(%{filename: filename, storage_dir: storage_dir, storage_opts: version_storage_opts} = version_state, _version, %{path: path, storage: storage, storage_opts: storage_opts}) do
    :ok = storage.save(storage_dir, filename, version_state.temp_path || path, Keyword.merge(storage_opts, version_storage_opts))

    {:ok, version_state}
  end

  defp delete_version(%{filename: filename, storage_dir: storage_dir} = version_state, _version, %{storage: storage, storage_opts: storage_opts}) do
    :ok = storage.delete(storage_dir, filename, storage_opts)

    {:ok, version_state}
  end

  defp ok(%State{errors: nil} = state), do: {:ok, state}
  defp ok(%State{} = state), do: {:error, state}
  defp ok(other), do: {:ok, other}
end
