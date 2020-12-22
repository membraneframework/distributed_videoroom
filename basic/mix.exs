defmodule Membrane.Demo.Basic.MixProject do
  use Mix.Project

  @version "0.5.0"
  @github_url "https://github.com/membraneframework/membrane-demo"

  def project do
    [
      app: :membrane_demo_basic,
      version: @version,
      elixir: "~> 1.10",
      name: "Membrane Demo",
      description: "Membrane Multimedia Framework (Basic Demo Applications)",
      homepage_url: "https://membraneframework.org",
      source_url: @github_url,
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 0.6.0", override: true},
      {:membrane_file_plugin, "~> 0.5.0"},
      {:membrane_portaudio_plugin, "~> 0.4.0"},
      {:membrane_ffmpeg_swresample_plugin, "~> 0.4.0"},
      {:membrane_mp3_mad_plugin, "~> 0.4.0"},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev], runtime: false}
    ]
  end
end