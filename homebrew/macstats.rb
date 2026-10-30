cask "macstats" do
  version "1.2.1"
  sha256 "a05e2e073a7ced63305d8197bfbd18d13761296f915b0a5d25f46f3d5b295be1"

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
