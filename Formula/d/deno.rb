class Deno < Formula
  desc "Secure runtime for JavaScript and TypeScript"
  homepage "https://deno.com/"
  url "https://github.com/denoland/deno/releases/download/v2.1.0/deno_src.tar.gz"
  sha256 "2318042f2385c96e83cf365626d3fd19fcb1a6af488527c0820370490f94a9af"
  license "MIT"
  head "https://github.com/denoland/deno.git", branch: "main"

  bottle do
    sha256 cellar: :any,                 arm64_sequoia: "f015ec94bdffaecf267d56dd0baef2a05822ee83f602caf17034d619253ec341"
    sha256 cellar: :any,                 arm64_sonoma:  "9a7b9e1c39d1f9f2f3a77739dafd8420f8ed34944f671c76298c73725ed02495"
    sha256 cellar: :any,                 arm64_ventura: "833bb7836592e80a2bb85f5a9cd527a29bcb2dc01dc712e794c56cf927139182"
    sha256 cellar: :any,                 sonoma:        "29443d0c3fa185e5326ff16a40eaf0895e70d889bb41c23bb123355acfc4b853"
    sha256 cellar: :any,                 ventura:       "d72aab5a228b8d4471af53384d760e6b235333b104ec9f232da40f22cf535fcb"
    sha256 cellar: :any_skip_relocation, x86_64_linux:  "7ac0f094c89734d1a018425721986e44c526ab9742fd05f25772777f0e391948"
  end

  depends_on "cmake" => :build
  depends_on "llvm@18" => :build
  depends_on "ninja" => :build
  depends_on "protobuf" => :build
  depends_on "rust" => :build
  depends_on xcode: ["15.0", :build] # v8 12.9+ uses linker flags introduced in xcode 15
  depends_on "sqlite" # needs `sqlite3_unlock_notify`

  uses_from_macos "python" => :build, since: :catalina
  uses_from_macos "libffi"
  uses_from_macos "xz"
  uses_from_macos "zlib"

  on_linux do
    depends_on "pkg-config" => :build
    depends_on "glib"
  end

  fails_with gcc: "5"

  # Temporary resources to work around build failure due to files missing from crate
  # We use the crate as GitHub tarball lacks submodules and this allows us to avoid git overhead.
  # TODO: Remove this and `v8` resource when https://github.com/denoland/rusty_v8/issues/1065 is resolved
  # VERSION=#{version} && curl -s https://raw.githubusercontent.com/denoland/deno/v$VERSION/Cargo.lock | grep -C 1 'name = "v8"'
  resource "rusty_v8" do
    url "https://static.crates.io/crates/v8/v8-0.106.0.crate"
    sha256 "a381badc47c6f15acb5fe0b5b40234162349ed9d4e4fd7c83a7f5547c0fc69c5"
  end

  # Find the v8 version from the last commit message at:
  # https://github.com/denoland/rusty_v8/commits/v#{rusty_v8_version}/v8
  # Then, use the corresponding tag found in https://github.com/denoland/v8/tags
  resource "v8" do
    url "https://github.com/denoland/v8/archive/refs/tags/12.9.202.13-denoland-245ce17ed8483e6bc3de.tar.gz"
    sha256 "63cd3d4a42cac18a7475165f8c623cfdae8782d0fedea9aa030f983e987c8309"
  end

  # VERSION=#{version} && curl -s https://raw.githubusercontent.com/denoland/deno/v$VERSION/Cargo.lock | grep -C 1 'name = "deno_core"'
  resource "deno_core" do
    url "https://github.com/denoland/deno_core/archive/refs/tags/0.318.0.tar.gz"
    sha256 "c33b5c9ce2e5fccf8f6b3c9015bddef2949dcd2fc492e4d8ce6b3fadf93ec85f"
  end

  # The latest commit from `denoland/icu`, go to https://github.com/denoland/rusty_v8/tree/v#{rusty_v8_version}/third_party
  # and check the commit of the `icu` directory
  resource "icu" do
    url "https://github.com/denoland/icu/archive/a22a8f24224ddda8b856437d7e8560de1da3f8e1.tar.gz"
    sha256 "649c1d76e08e3bfb87ebc478bed2a1909e5505aadc98ebe71406c550626b4225"
  end

  # V8_TAG=#{v8_resource_tag} && curl -s https://raw.githubusercontent.com/denoland/v8/$V8_TAG/DEPS | grep gn_version
  resource "gn" do
    url "https://gn.googlesource.com/gn.git",
        revision: "54f5b539df8c4e460b18c62a11132d77b5601136"
  end

  def llvm
    Formula["llvm@18"]
  end

  def install
    # Work around files missing from crate
    # TODO: Remove this at the same time as `rusty_v8` + `v8` resources
    resource("rusty_v8").stage buildpath/"../rusty_v8"
    resource("v8").stage do
      cp_r "tools/builtins-pgo", buildpath/"../rusty_v8/v8/tools/builtins-pgo"
    end
    resource("icu").stage do
      cp_r "common", buildpath/"../rusty_v8/third_party/icu/common"
    end

    resource("deno_core").stage buildpath/"../deno_core"

    # Avoid vendored dependencies.
    inreplace "ext/ffi/Cargo.toml",
              /^libffi-sys = "(.+)"$/,
              'libffi-sys = { version = "\\1", features = ["system"] }'
    inreplace "Cargo.toml",
              /^rusqlite = { version = "(.+)", features = \["unlock_notify", "bundled"\] }$/,
              'rusqlite = { version = "\\1", features = ["unlock_notify"] }'

    if OS.mac? && (MacOS.version < :mojave)
      # Overwrite Chromium minimum SDK version of 10.15
      ENV["FORCE_MAC_SDK_MIN"] = MacOS.version
    end

    python3 = which("python3")
    # env args for building a release build with our python3, ninja and gn
    ENV["PYTHON"] = python3
    ENV["GN"] = buildpath/"gn/out/gn"
    ENV["NINJA"] = which("ninja")
    # build rusty_v8 from source
    ENV["V8_FROM_SOURCE"] = "1"
    # Build with llvm and link against system libc++ (no runtime dep)
    ENV["CLANG_BASE_PATH"] = llvm.prefix

    # use our clang version, and disable lld because the build assumes the lld
    # supports features from newer clang versions (>=20)
    clang_version = llvm.version.major
    ENV["GN_ARGS"] = "clang_version=#{clang_version} use_lld=false"

    # Work around an Xcode 15 linker issue which causes linkage against LLVM's
    # libunwind due to it being present in a library search path.
    ENV.remove "HOMEBREW_LIBRARY_PATHS", llvm.opt_lib

    resource("gn").stage buildpath/"gn"
    cd "gn" do
      system python3, "build/gen.py"
      system "ninja", "-C", "out"
    end

    # cargo seems to build rusty_v8 twice in parallel, which causes problems,
    # hence the need for ENV.deparallelize
    # Issue ref: https://github.com/denoland/deno/issues/9244
    ENV.deparallelize do
      system "cargo", "--config", ".cargo/local-build.toml",
                      "install", "--no-default-features", "-vv",
                      *std_cargo_args(path: "cli")
    end

    generate_completions_from_executable(bin/"deno", "completions")
  end

  def check_binary_linkage(binary, library)
    binary.dynamically_linked_libraries.any? do |dll|
      next false unless dll.start_with?(HOMEBREW_PREFIX.to_s)

      File.realpath(dll) == File.realpath(library)
    end
  end

  test do
    IO.popen("deno run -A -r https://fresh.deno.dev fresh-project", "r+") do |pipe|
      pipe.puts "n"
      pipe.puts "n"
      pipe.close_write
      pipe.read
    end

    assert_match "# Fresh project", (testpath/"fresh-project/README.md").read

    (testpath/"hello.ts").write <<~EOS
      console.log("hello", "deno");
    EOS
    assert_match "hello deno", shell_output("#{bin}/deno run hello.ts")
    assert_match "Welcome to Deno!",
      shell_output("#{bin}/deno run https://deno.land/std@0.100.0/examples/welcome.ts")

    linked_libraries = [
      Formula["sqlite"].opt_lib/shared_library("libsqlite3"),
    ]
    unless OS.mac?
      linked_libraries += [
        Formula["libffi"].opt_lib/shared_library("libffi"),
        Formula["zlib"].opt_lib/shared_library("libz"),
      ]
    end
    linked_libraries.each do |library|
      assert check_binary_linkage(bin/"deno", library),
              "No linkage with #{library.basename}! Cargo is likely using a vendored version."
    end
  end
end
