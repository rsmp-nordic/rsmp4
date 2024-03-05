defmodule RSMP.Site.Web.SiteLive.Site do
  use RSMP.Site.Web, :live_view
  alias RSMP.Site
  require Logger

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
       alarm_flags: RSMP.Alarm.get_flag_keys()
     )}
  end

  def connected_mount(params, _session, socket) do
    Phoenix.PubSub.subscribe(RSMP.PubSub, "rsmp")

    site_id = params["site_id"]

    #id = RSMP.Site.TLC.make_site_id()

    {:ok, pid} = Site.TLC.start_link(site_id: site_id)

    {:ok,
     assign(socket,
       rsmp_site_id: pid,
       id: Site.get_id(pid),
       statuses: Site.get_statuses(pid),
       alarms: alarm_map(Site.get_alarms(pid)),
       alarm_flags: RSMP.Alarm.get_flag_keys()
     )}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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
  def handle_event("increase", data, socket) do
    change_status(data, socket, 1)
  end

  @impl true
  def handle_event("decrease", data, socket) do
    change_status(data, socket, -1)
  end

  @impl true
  def handle_event("alarm", %{"path" => path, "value" => flag} = _data, socket) do
    pid = socket.assigns[:rsmp_site_id]
    Site.toggle_alarm_flag(pid, path, RSMP.Alarm.flag_atom_from_string(flag))
    {:noreply, socket}
  end

  @impl true
  def handle_event(_name, _data, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(%{topic: "status", changes: _changes}, socket) do
    pid = socket.assigns[:rsmp_site_id]
    statuses = Site.get_statuses(pid)
    {:noreply, assign(socket, statuses: statuses)}
  end

  @impl true
  def handle_info(%{topic: "alarm", changes: _changes}, socket) do
    pid = socket.assigns[:rsmp_site_id]
    alarms = Site.get_alarms(pid)
    {:noreply, assign(socket, alarms: alarm_map(alarms))}
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
