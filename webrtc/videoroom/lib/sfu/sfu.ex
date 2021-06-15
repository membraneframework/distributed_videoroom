defmodule Membrane.SFU do
  use Membrane.Pipeline

  require Membrane.Logger

  alias Membrane.WebRTC.{Endpoint, EndpointBin, Track}
  alias Membrane.SFU.{MediaEvent, PrivateKey}

  @registry_name Membrane.SFU.Registry.Dispatcher

  @type stun_server_t() :: ExLibnice.stun_server()
  @type turn_server_t() :: ExLibnice.relay_info()

  @type extension_options_t() :: [
          vad: boolean()
        ]

  @type network_options_t() :: [
          stun_servers: [stun_server_t()],
          turn_servers: [turn_server_t()],
          dtls_pkey: binary(),
          dtls_cert: binary()
        ]

  @type options_t() :: [
          id: String.t(),
          extension_options: extension_options_t(),
          network_options: network_options_t()
        ]

  @spec start(options :: options_t(), process_options :: GenServer.options()) ::
          GenServer.on_start()
  def start(options, process_options) do
    do_start(:start, options, process_options)
  end

  @spec start_link(options :: options_t(), process_options :: GenServer.options()) ::
          GenServer.on_start()
  def start_link(options, process_options) do
    do_start(:start_link, options, process_options)
  end

  defp do_start(func, options, process_options) when func in [:start, :start_link] do
    id = options[:id] || "#{UUID.uuid4()}"
    options = Keyword.put(options, :id, id)

    Membrane.Logger.info("Starting a new SFU instance with id: #{id}")

    apply(Membrane.Pipeline, func, [
      __MODULE__,
      options,
      process_options
    ])
  end

  @impl true
  def handle_init(options) do
    play(self())
    {:ok, _pid} = Registry.start_link(keys: :duplicate, name: @registry_name)

    {{:ok, log_metadata: [sfu: options[:id]]},
     %{id: options[:id], peers: %{}, endpoints: %{}, options: options}}
  end

  @impl true
  def handle_other({:register, pid}, _ctx, state) do
    Registry.register(@registry_name, :sfu, pid)
    {:ok, state}
  end

  @impl true
  def handle_other({:unregister, pid}, _ctx, state) do
    Registry.unregister_match(@registry_name, :sfu, pid)
    {:ok, state}
  end

  @impl true
  def handle_other({:remove_peer, id}, ctx, state) do
    {actions, state} = remove_peer(id, ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_other({:media_event, data}, ctx, state) do
    case MediaEvent.deserialize(data) do
      {:ok, event} ->
        {actions, state} = handle_media_event(event, ctx, state)
        {{:ok, actions}, state}

      {:error, :invalid_media_event} ->
        Membrane.Logger.info("Invalid media event #{inspect(data)}")
        {:ok, state}
    end
  end

  defp handle_media_event(%{type: :join, key: key, data: data} = event, ctx, state) do
    {actions, state} =
      if PrivateKey.is_valid(key) do
        dispatch({:new_peer, data.id, data.metadata, data.track_metadata})

        receive do
          {:accept_new_peer, peer_id} ->
            cond do
              peer_id != data.id ->
                Membrane.Logger.info("Unknown peer id passed for acceptance: #{inspect(peer_id)}")
                {[], state}

              Map.has_key?(state.peers, key) ->
                Membrane.Logger.info("Peer with id: #{inspect(peer_id)} has already been added")
                {[], state}

              true ->
                peer = Map.put(data, :key, key)
                state = put_in(state, [:peers, key], peer)
                {actions, state} = setup_peer(data, ctx, state)

                MediaEvent.create_peer_accepted_event(peer_id, Map.delete(state.peers, key))
                |> dispatch()

                {actions, state}
            end

          {:deny_new_peer, peer_id} ->
            MediaEvent.create_peer_denied_event(peer_id)
            |> dispatch()

            {[], state}
        end
      else
        Membrane.Logger.info("Invalid private key in media event: #{inspect(event)}")
        {[], state}
      end

    {actions, state}
  end

  defp handle_media_event(%{type: :answer} = event, _ctx, state) do
    peer_id = state.peers[event.key].id
    {_track_metadata, state} = pop_in(state, [:peers, peer_id, :track_metadata])

    state =
      put_in(state, [:peers, peer_id, :mid_to_track_metadata], event.data.mid_to_track_metadata)

    {{:ok, forward: {{:endpoint, peer_id}, {:signal, {:sdp_answer, event.data.sdp_answer.sdp}}}},
     state}
  end

  defp handle_media_event(%{type: :candidate} = event, _ctx, state) do
    peer_id = state.peers[event.key].id
    {{:ok, forward: {{:endpoint, peer_id}, {:signal, {:candidate, event.candidate}}}}, state}
  end

  defp handle_media_event(%{type: :leave} = event, ctx, state) do
    peer_id = state.peers[event.key].id
    {actions, state} = remove_peer(peer_id, ctx, state)
    {{:ok, actions}, state}
  end

  @impl true
  def handle_notification({:signal, message}, {:endpoint, peer_id}, _ctx, state) do
    MediaEvent.create_signal_event(peer_id, {:signal, message})
    |> dispatch()

    {:ok, state}
  end

  @impl true
  def handle_notification({:new_track, track_id, encoding}, endpoint_bin_name, ctx, state) do
    Membrane.Logger.info("New incoming #{encoding} track #{track_id}")
    {:endpoint, endpoint_id} = endpoint_bin_name

    tee = {:tee, {endpoint_id, track_id}}
    fake = {:fake, {endpoint_id, track_id}}

    children = %{
      tee => Membrane.Element.Tee.Master,
      fake => Membrane.Element.Fake.Sink.Buffers
    }

    extensions = setup_extensions(encoding, state.options.extension_options)

    links =
      [
        link(endpoint_bin_name)
        |> via_out(Pad.ref(:output, track_id), options: [extensions: extensions])
        |> to(tee)
        |> via_out(:master)
        |> to(fake)
      ] ++
        flat_map_children(ctx, fn
          {:endpoint, other_endpoint_id} = other_endpoint_name ->
            if endpoint_bin_name != other_endpoint_name and
                 state.endpoints[other_endpoint_id].ctx.receive_media do
              [
                link(tee)
                |> via_out(:copy)
                |> via_in(Pad.ref(:input, track_id), options: [encoding: encoding])
                |> to(other_endpoint_name)
              ]
            else
              []
            end
        end)

    spec = %ParentSpec{children: children, links: links, crash_group: {endpoint_id, :temporary}}

    state =
      update_in(
        state,
        [:endpoints, endpoint_id],
        &Endpoint.update_track_encoding(&1, track_id, encoding)
      )

    {{:ok, spec: spec}, state}
  end

  def handle_notification({:vad, val}, {:endpoint, endpoint_id}, _ctx, state) do
    dispatch({:vad_notification, val, endpoint_id})
    {:ok, state}
  end

  defp dispatch(msg) do
    Registry.dispatch(@registry_name, :sfu, fn entries ->
      for {_, pid} <- entries, do: send(pid, {self(), msg})
    end)
  end

  defp setup_peer(config, ctx, state) do
    inbound_tracks = create_inbound_tracks(config.relay_audio, config.relay_video)
    outbound_tracks = get_outbound_tracks(state.endpoints, config.receive_media)

    # FIXME `type` field should probably be deleted from Endpoint struct
    endpoint =
      Endpoint.new(config.id, :participant, inbound_tracks, %{receive_media: config.receive_media})

    endpoint_bin_name = {:endpoint, config.id}

    handshake_opts =
      if state.options[:network_options][:dtls_pkey] &&
           state.options[:network_options][:dtls_cert] do
        [
          client_mode: false,
          dtls_srtp: true,
          pkey: state.options.network_options.dtls_pkey,
          cert: state.options.network_options.dtls_cert
        ]
      else
        [
          client_mode: false,
          dtls_srtp: true
        ]
      end

    children = %{
      endpoint_bin_name => %EndpointBin{
        outbound_tracks: outbound_tracks,
        inbound_tracks: inbound_tracks,
        stun_servers: state.options[:network_options][:stun_servers] || [],
        turn_servers: state.options[:network_options][:turn_servers] || [],
        handshake_opts: handshake_opts,
        log_metadata: [peer_id: config.id]
      }
    }

    links = create_links(config.receive_media, endpoint_bin_name, ctx, state)

    spec = %ParentSpec{children: children, links: links, crash_group: {config.id, :temporary}}

    state = put_in(state.endpoints[config.id], endpoint)

    {[spec: spec], state}
  end

  defp create_inbound_tracks(relay_audio, relay_video) do
    stream_id = Track.stream_id()
    audio_track = if relay_audio, do: [Track.new(:audio, stream_id)], else: []
    video_track = if relay_video, do: [Track.new(:video, stream_id)], else: []
    audio_track ++ video_track
  end

  defp get_outbound_tracks(endpoints, true) do
    Enum.flat_map(endpoints, fn {_id, endpoint} -> Endpoint.get_tracks(endpoint) end)
  end

  defp get_outbound_tracks(_endpoints, false), do: []

  defp create_links(_receive_media = true, new_endpoint_bin_name, ctx, state) do
    flat_map_children(ctx, fn
      {:tee, {endpoint_id, track_id}} = tee ->
        endpoint = state.endpoints[endpoint_id]
        track = Endpoint.get_track_by_id(endpoint, track_id)

        [
          link(tee)
          |> via_out(:copy)
          |> via_in(Pad.ref(:input, track_id), options: [encoding: track.encoding])
          |> to(new_endpoint_bin_name)
        ]

      _child ->
        []
    end)
  end

  defp create_links(_receive_media = false, _endpoint, _ctx, _state) do
    []
  end

  defp setup_extensions(encoding, extension_options) do
    if encoding == :OPUS and extension_options.vad, do: [{:vad, Membrane.RTP.VAD}], else: []
  end

  defp remove_peer(peer_id, ctx, state) do
    case do_remove_peer(peer_id, ctx, state) do
      {:absent, [], state} ->
        Membrane.Logger.info("Peer #{inspect(peer_id)} already removed")
        {[], state}

      {:present, actions, state} ->
        dispatch({:peer_left, peer_id})
        {actions, state}
    end
  end

  defp do_remove_peer(peer_id, ctx, state) do
    if !Map.has_key?(state.endpoints, peer_id) do
      {:absent, [], state}
    else
      {endpoint, state} = pop_in(state, [:endpoints, peer_id])
      tracks = Enum.map(Endpoint.get_tracks(endpoint), &%Track{&1 | enabled?: false})

      tracks_msgs = update_track_messages(ctx, tracks, {:endpoint, peer_id}, state)

      endpoint_bin = ctx.children[{:endpoint, peer_id}]

      actions =
        if endpoint_bin == nil or endpoint_bin.terminating? do
          []
        else
          children =
            Endpoint.get_tracks(endpoint)
            |> Enum.map(fn track -> track.id end)
            |> Enum.flat_map(&[tee: {peer_id, &1}, fake: {peer_id, &1}])
            |> Enum.filter(&Map.has_key?(ctx.children, &1))

          children = [endpoint: peer_id] ++ children
          [remove_child: children]
        end

      {:present, tracks_msgs ++ actions, state}
    end
  end

  defp update_track_messages(_ctx, [] = _tracks, _endpoint_bin, _state), do: []

  defp update_track_messages(ctx, tracks, endpoint_bin, state) do
    flat_map_children(ctx, fn
      {:endpoint, other_peer_pid} = other_endpoint_bin
      when other_endpoint_bin != endpoint_bin and other_peer_pid != state.active_screensharing ->
        [forward: {other_endpoint_bin, {:add_tracks, tracks}}]

      _child ->
        []
    end)
  end

  defp flat_map_children(ctx, fun) do
    ctx.children |> Map.keys() |> Enum.flat_map(fun)
  end
end