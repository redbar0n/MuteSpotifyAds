cask "mutefy" do
  version "2.0.0"
  sha256 "34acfc72f9c9d75eb75850c9e74d97b55c0450360eb855436b216767e24a941c"

  url "https://github.com/countnine/MuteSpotifyAds/releases/download/v#{version}/Mutefy.app.tar.gz"
  name "Mutefy"
  desc "Mutes Spotify ads and optionally plays your own music"
  homepage "https://github.com/countnine/MuteSpotifyAds"

  app "Mutefy.app"
end
