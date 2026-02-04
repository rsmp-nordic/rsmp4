defmodule RSMP.Site.Web.SiteLive.Site do
  use RSMP.Site.Web, :live_view
  alias RSMP.Site
  alias RSMP.Node.TLC

  @impl true
  def mount(params, session, socket) do
    case connected?(socket) do
      false ->
        initial_mount(params, session, socket)

      true ->
        connected_mount(params, session, socket)
    end
  end

  def initial_mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page: "loading",
       id: "",
       statuses: %{},
       alarms: %{},
       command_logs: [],
       alarm_flags: RSMP.Alarm.get_flag_keys()
     )}
  end

  def connected_mount(params, _session, socket) do
    site_id = params["site_id"]
    Phoenix.PubSub.subscribe(RSMP.PubSub, "rsmp:#{site_id}")

    # id = TLC.make_site_id()

    {:ok, pid} = TLC.start_link(site_id)

    statuses = TLC.get_statuses(site_id)
    alarms = TLC.get_alarms(site_id)

    {:ok,
     assign(socket,
       rsmp_site_id: pid,
       id: site_id,
       statuses: statuses,
       alarms: alarm_map(alarms),
       command_logs: [],
       alarm_flags: RSMP.Alarm.get_flag_keys()
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    site_id = params["site_id"]

    if site_id do
      {:noreply, socket}
    else
      site_id = TLC.make_site_id()
      {:noreply, push_patch(socket, to: ~p"/site/#{site_id}")}
    end
  end

  def change_status(data, socket, delta) do
    path = data["value"]
    pid = socket.assigns[:rsmp_site_id]
    statuses = Site.get_statuses(pid)
    new_value = statuses[path] + delta
    Site.set_status(pid, path, new_value)

    if path == "./env/temperature" do
      if new_value >= 30 do
        Site.raise_alarm(pid, path)
      else
        Site.clear_alarm(pid, path)
      end
    end

    if path == "./env/humidity" do
      if new_value >= 50 do
        Site.raise_alarm(pid, path)
      else
        Site.clear_alarm(pid, path)
      end
    end

    statuses = Site.get_statuses(pid)
    {:noreply, assign(socket, statuses: statuses)}
  end

  @impl true
  def handle_event("alarm", data, socket) do
     path = data["path"]
     flag = data["value"]
     site_id = socket.assigns[:id]

     alarms = TLC.get_alarms(site_id)
     current_alarm = alarms[path]
     new_value = not Map.get(current_alarm, String.to_atom(flag))
     TLC.set_alarm(site_id, path, %{flag => new_value})

     alarms = TLC.get_alarms(site_id)
     {:noreply, assign(socket, alarms: alarm_map(alarms))}
  end

  @impl true
  def handle_event(_name, _data, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "alarm"}, socket) do
    site_id = socket.assigns[:id]
    alarms = TLC.get_alarms(site_id)
    {:noreply, assign(socket, alarms: alarm_map(alarms))}
  end

  @impl true
  def handle_info(%{topic: "status"}, socket) do
    statuses = TLC.get_statuses(socket.assigns.id)
    {:noreply, assign(socket, statuses: statuses)}
  end

  @impl true
  def handle_info(%{topic: "command_log", id: id, message: message}, socket) do
    logs = socket.assigns.command_logs
    new_logs = logs ++ [%{id: id, message: message}]
    new_logs = if length(new_logs) > 5, do: Enum.drop(new_logs, length(new_logs) - 5), else: new_logs
    {:noreply, assign(socket, command_logs: new_logs)}
  end

  # Change tracking on assigns only works with simple data, we
  # cannot use functions to extract data in our templates.
  # Convert alarm structs to plain maps.
  def alarm_map(alarms) do
    alarms
    |> Enum.map(fn {path, alarm} -> {path, Map.from_struct(alarm)} end)
    |> Enum.into(%{})
  end
end
