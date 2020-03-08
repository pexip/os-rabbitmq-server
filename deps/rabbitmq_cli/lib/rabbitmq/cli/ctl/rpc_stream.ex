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

defmodule RabbitMQ.CLI.Ctl.RpcStream do
  alias RabbitMQ.CLI.Ctl.InfoKeys

  def receive_list_items(node, mod, fun, args, timeout, info_keys) do
    receive_list_items(node, [{mod, fun, args}], timeout, info_keys, 1)
  end

  def receive_list_items(node, mod, fun, args, timeout, info_keys, chunks) do
    receive_list_items(node, [{mod, fun, args}], timeout, info_keys, chunks)
  end

  def receive_list_items(_node, _mfas, _timeout, _info_keys, 0) do
    nil
  end

  def receive_list_items(node, mfas, timeout, info_keys, chunks_init) do
    receive_list_items_with_fun(node, mfas, timeout, info_keys, chunks_init, fn(v) -> v end)
  end

  def receive_list_items_with_fun(node, mfas, timeout, info_keys, chunks_init, response_fun) do
    pid = Kernel.self
    ref = Kernel.make_ref
    for {m,f,a} <- mfas, do: init_items_stream(node, m, f, a, timeout, pid, ref)
    Stream.unfold({chunks_init, :continue},
      fn
        :finished -> response_fun.(nil);
        {chunks, :continue} ->
          received = receive do
            {^ref, :finished} when chunks === 1 -> nil;
            {^ref, :finished}         -> {[], {chunks - 1, :continue}};
            {^ref, {:timeout, t}}     -> {{:error, {:badrpc, {:timeout, (t / 1000)}}}, :finished};
            {^ref, []}                -> {[], {chunks, :continue}};
            {^ref, :error, {:badrpc, :timeout}} -> {{:error, {:badrpc, {:timeout, (timeout / 1000)}}}, :finished};
            {^ref, result, :continue} -> {result, {chunks, :continue}};
            {:error, _} = error       -> {error,  :finished};
            {^ref, :error, error}     -> {{:error, simplify_emission_error(error)}, :finished};
            {:DOWN, _mref, :process, _pid, :normal} -> {[], {chunks, :continue}};
            {:DOWN, _mref, :process, _pid, reason}  ->  {{:error, simplify_emission_error(reason)}, :finished}
          end
          response_fun.(received)
      end)
    |> display_list_items(info_keys)
  end

  def simplify_emission_error({:badrpc, {'EXIT', {{:nocatch, error}, _}}}) do
    error
  end

  def simplify_emission_error({{:nocatch, error}, _}) do
    error
  end

  def simplify_emission_error(other) do
    other
  end

  defp display_list_items(items, info_keys) do
    items
    |> Stream.filter(fn([]) -> false; (_) -> true end)
    |> Stream.map(
        fn({:error, _} = error) -> error;
          # here item is a list of keyword lists:
          ([[{_, _} | _] | _] = item) ->
            Enum.map(item, fn(i) -> InfoKeys.info_for_keys(i, info_keys) end);
          (item) ->
            InfoKeys.info_for_keys(item, info_keys)
        end)
  end

  defp init_items_stream(node, mod, fun, args, timeout, pid, ref) do
    :rabbit_control_misc.spawn_emitter_caller(node, mod, fun, args, ref, pid, timeout)
    set_stream_timeout(pid, ref, timeout)
  end

  defp set_stream_timeout(_, _, :infinity) do
    :ok
  end
  defp set_stream_timeout(pid, ref, timeout) do
    Process.send_after(pid, {ref, {:timeout, timeout}}, timeout)
  end
end
