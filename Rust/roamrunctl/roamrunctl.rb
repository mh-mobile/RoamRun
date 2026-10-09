# The tap's Formula/roamrunctl.rb (mh-mobile/homebrew-tap): copied there at each release with
# that tag in `url` and the sha256 of its tarball. Built from source, so nothing is to be notarized.
class Roamrunctl < Formula
  desc "Introduces a far Mac to an iPhone, from a machine that has no RoamRun"
  homepage "https://github.com/mh-mobile/RoamRun"
  url "https://github.com/mh-mobile/RoamRun/archive/refs/tags/v0.5.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/mh-mobile/RoamRun.git", branch: "main"

  depends_on "rust" => :build

  def install
    cd "Rust/roamrunctl" do
      system "cargo", "install", *std_cargo_args
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/roamrunctl --version")
  end
end
