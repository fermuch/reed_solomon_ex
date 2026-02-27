defmodule ReedSolomonEx.MixProject do
  use Mix.Project

  @source_url "https://github.com/fermuch/reed_solomon_ex"
  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :reed_solomon_ex,
      description: description(),
      package: package(),
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: [
        extras: ["README.md"],
        main: "readme",
        source_url: @source_url,
        source_ref: "v#{@version}"
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler_precompiled, "~> 0.8"},
      {:rustler, "~> 0.37", optional: true},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Elixir/Rust wrapper around Reed-Solomon error correction code library.
    Suitable for protecting short binary packets against bit errors on noisy channels.
    """
  end

  defp package do
    %{
      name: "reed_solomon_ex",
      files:
        [
          "lib",
          "mix.exs",
          "README.md",
          "LICENSE",
          "VERSION",
          "checksum-*.exs"
        ] ++ native_files(),
      maintainers: ["Fernando Mumbach"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    }
  end

  defp native_files do
    {out, 0} = System.cmd("git", ["ls-files", "native"])

    out
    |> String.split("\n")
    |> Enum.filter(&(&1 != ""))
  end
end
