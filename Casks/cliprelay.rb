cask "cliprelay" do
  version "0.7.3"
  sha256 "2955e84cd456d2add4923183d79be8328286d494c8ab2887a808eae5aabdb4e4"

  url "https://github.com/geekflyer/cliprelay/releases/download/mac/v#{version}/ClipRelay-#{version}.dmg"
  name "ClipRelay"
  desc "Clipboard sharing with Android devices over Bluetooth"
  homepage "https://cliprelay.org/"

  livecheck do
    url "https://updates.cliprelay.org/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :ventura

  app "ClipRelay.app"

  zap trash: [
    "~/Library/Application Support/ClipRelay",
    "~/Library/Preferences/org.cliprelay.mac.plist",
  ]
end
