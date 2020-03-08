## The contents of this file are subject to the Mozilla Public License
## Version 1.1 (the "License"); you may not use this file except in
## compliance with the License. You may obtain a copy of the License
## at http://www.mozilla.org/MPL/
##
## Software distributed under the License is distributed on an "AS IS"
## basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
## the License for the specific language governing rights and
## limitations under the License.
##
## The Original Code is RabbitMQ.
##
## The Initial Developer of the Original Code is GoPivotal, Inc.
## Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.


defmodule RabbitMQ.CLI.Plugins.Commands.EnableCommand do
  alias RabbitMQ.CLI.Plugins.Helpers, as: PluginHelpers
  alias RabbitMQ.CLI.Core.{Helpers, Validators}

  @behaviour RabbitMQ.CLI.CommandBehaviour

  def formatter(), do: RabbitMQ.CLI.Formatters.Plugins

  def merge_defaults(args, opts) do
    {args, Map.merge(%{online: false, offline: false, all: false}, opts)}
  end

  def distribution(%{offline: true}),  do: :none
  def distribution(%{offline: false}), do: :cli

  def switches(), do: [online: :boolean,
                       offline: :boolean,
                       all: :boolean]

  def validate([], %{all: false}) do
    {:validation_failure, :not_enough_arguments}
  end
  def validate([_ | _], %{all: true}) do
    {:validation_failure,
      {:bad_argument, "Cannot set both --all and a list of plugins"}}
  end
  def validate(_, %{online: true, offline: true}) do
    {:validation_failure, {:bad_argument, "Cannot set both online and offline"}}
  end
  def validate(_, _) do
    :ok
  end

  def validate_execution_environment(args, opts) do
    Validators.chain([&PluginHelpers.can_set_plugins_with_mode/2,
                      &Helpers.require_rabbit_and_plugins/2,
                      &PluginHelpers.enabled_plugins_file/2,
                      &Helpers.plugins_dir/2],
                     [args, opts])
  end

  def usage, do: "enable <plugin>|--all [--offline] [--online]"

  def banner([], %{all: true, node: node_name}) do
    "Enabling ALL plugins on node #{node_name}"
  end
  def banner(plugins, %{node: node_name}) do
    ["Enabling plugins on node #{node_name}:" | plugins]
  end


  def run(plugin_names, %{all: all_flag} = opts) do
    plugins = case all_flag do
      false -> for s <- plugin_names, do: String.to_atom(s);
      true  -> PluginHelpers.plugin_names(PluginHelpers.list(opts))
    end

    case PluginHelpers.validate_plugins(plugins, opts) do
      :ok   -> do_run(plugins, opts)
      other -> other
    end
  end

  def do_run(plugins, %{node: node_name} = opts) do
    enabled = PluginHelpers.read_enabled(opts)
    all     = PluginHelpers.list(opts)
    implicit           = :rabbit_plugins.dependencies(false, enabled, all)
    enabled_implicitly = MapSet.difference(MapSet.new(implicit), MapSet.new(enabled))

    plugins_to_set = MapSet.union(
      MapSet.new(enabled),
      MapSet.difference(MapSet.new(plugins), enabled_implicitly))

    mode = PluginHelpers.mode(opts)
    case PluginHelpers.set_enabled_plugins(MapSet.to_list(plugins_to_set), opts) do
      {:ok, enabled_plugins} ->
        {:stream, Stream.concat(
            [[:rabbit_plugins.strictly_plugins(enabled_plugins, all)],
             RabbitMQ.CLI.Core.Helpers.defer(
               fn() ->
                 case PluginHelpers.update_enabled_plugins(enabled_plugins, mode,
                       node_name, opts) do
                   %{set: new_enabled} = result ->
                     enabled = new_enabled -- implicit
                     filter_strictly_plugins(Map.put(result, :enabled, :rabbit_plugins.strictly_plugins(enabled, all)), all, [:set, :started, :stopped]);
                   other -> other
                 end
               end)])};
      {:error, _} = err ->
        err
    end
  end

  defp filter_strictly_plugins(map, _all, []) do
    map
  end
  defp filter_strictly_plugins(map, all, [head | tail]) do
    case map[head] do
      nil ->
        filter_strictly_plugins(map, all, tail);
      other ->
        value = :rabbit_plugins.strictly_plugins(other, all)
        filter_strictly_plugins(Map.put(map, head, value), all, tail)
    end
  end

  def output({:error, err}, _opts) do
    {:error, err}
  end
  def output({:stream, stream}, _opts) do
    {:stream, stream}
  end
end
