defmodule Website45sV3Web.Telemetry do
  @moduledoc """
  Defines the application's telemetry metrics.

  No reporter ships them anywhere: the only consumer is Phoenix LiveDashboard,
  mounted at `/dev/dashboard` in development (see the router), which reads
  `metrics/0`. The metrics cover the parts of the app that actually emit
  events — Phoenix (HTTP and channels), LiveView, Ecto and the VM. The poller
  is what produces the periodic `vm.*` measurements.
  """
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: [], period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # LiveView
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        tag_values: &live_view_tags/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_params.stop.duration",
        tags: [:view],
        tag_values: &live_view_tags/1,
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        tag_values: &live_view_tags/1,
        unit: {:native, :millisecond}
      ),

      # Database
      summary("website_45s_v3.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("website_45s_v3.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("website_45s_v3.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("website_45s_v3.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("website_45s_v3.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp live_view_tags(%{socket: socket} = metadata) do
    Map.put(metadata, :view, inspect(socket.view))
  end
end
