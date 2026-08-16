cask "bobrvm" do
  version :latest
  sha256 :no_check

  url "https://github.com/polymath-as/bobrvm/releases/download/tip/Bobrvm-tip-arm64.zip"
  name "bobrvm"
  desc "Virtualization software with accelerated Linux graphics"
  homepage "https://github.com/polymath-as/bobrvm"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Bobrvm.app"
end
