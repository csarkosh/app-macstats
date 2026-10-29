cask "macstats" do
  version "1.2.0"
  sha256 "6d3283dcc20b361969b8c92b20bf19d798382dfcec67a2e7aa1354e1682b50b7"

  url "https://github.com/csarkosh/app-macstats/releases/download/v#{version}/MacStats-#{version}-arm64.zip"
  name "MacStats"
  desc "Five menu bar items: CPU, GPU, RAM, Temp and free disk space"
  homepage "https://github.com/csarkosh/app-macstats"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "MacStats.app"
  # A command that runs the binary inside the bundle (a symlink would hide the bundle from it):
  # `macstats --cpu`, `macstats --version`, and the rest of its flags.
  command_wrapper "macstats", executable: "#{appdir}/MacStats.app/Contents/MacOS/MacStats"

  # A signal, not the quit Apple Event, so macOS never asks to let the terminal control the app.
  uninstall on_upgrade: :signal,
            signal:     [["TERM", "sh.csarko.MacStats"]]

  zap trash: [
    "~/Library/Caches/sh.csarko.MacStats",
    "~/Library/Preferences/sh.csarko.MacStats.plist",
  ]

  caveats <<~EOS
    Start MacStats with `open -a MacStats`. To start it at every login, add it in
    System Settings > General > Login Items. Right-click any item in the menu bar for Quit.
    This cask, the macstats formula and MacStats' own installer (curl | sh) are three ways in:
    use one, or two copies run.
  EOS
end
