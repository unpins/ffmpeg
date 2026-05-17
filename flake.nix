{
  description = "Standalone build of ffmpeg (headless)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;

      # nixpkgs's pkgsStatic.ffmpeg-headless pulls openapv/ocl-icd/
      # libtiff/libsndfile etc — codec deps that break under pkgsStatic.
      # We ship only the codecs we want and run configure ourselves.
      mkFfmpeg = pkgs:
        { extraConfigureFlags ? [ ]
        , extraInputs ? [ ]
        }:
        let
          stdenv = pkgs.stdenv;
          isMinGW = stdenv.hostPlatform.isMinGW or false;
          isDarwin = stdenv.hostPlatform.isDarwin;
          targetOs =
            if isMinGW then "mingw64"
            else if isDarwin then "darwin"
            else "linux";
          exe = if isMinGW then ".exe" else "";
          flags = [
            "--prefix=$out"
            "--cross-prefix=${stdenv.hostPlatform.config}-"
            # ffmpeg's cc_default="gcc" — appended after cross-prefix
            # this gives `arm64-apple-darwin-gcc`, which doesn't exist
            # on darwin (clang backend). Force the wrapper symlink that
            # exists across both clang and gcc nixpkgs cc-wrappers.
            "--cc=${stdenv.hostPlatform.config}-cc"
            "--host-cc=${pkgs.buildPackages.stdenv.cc}/bin/cc"
            # Hard-reference the cross pkg-config wrapper. Splicing in
            # nativeBuildInputs picks the BUILD-platform wrapper (named
            # after build triple), and ffmpeg's auto-derive (cross_prefix
            # + "pkg-config") expects a HOST-triple binary — match never
            # happens, pkg_config silently becomes "false", every probe
            # returns "not found". `pkgsBuildHost.pkg-config` (default,
            # pre-splicing) IS the host-triple wrapper; reference it by
            # explicit /bin path to bypass the splicing rewrite.
            "--pkg-config=${pkgs.pkgsBuildHost.pkg-config}/bin/${stdenv.hostPlatform.config}-pkg-config"
            "--enable-cross-compile"
            "--target-os=${targetOs}"
            "--arch=${stdenv.hostPlatform.uname.processor}"
            # ffmpeg's configure auto-derives pkg-config as
            # `${cross_prefix}pkg-config` — the binary the wrapper
            # actually ships. Don't pass `--pkg-config=pkg-config`
            # or it looks for a bare `pkg-config` that isn't in PATH.
            "--pkg-config-flags=--static"
            "--disable-doc" "--disable-htmlpages" "--disable-manpages"
            "--disable-podpages" "--disable-txtpages"
            "--disable-debug" "--disable-stripping"
            "--enable-gpl" "--enable-version3"
            "--enable-runtime-cpudetect" "--enable-network"
            "--disable-ffplay" "--enable-ffmpeg" "--enable-ffprobe"
            "--enable-zlib" "--enable-bzlib" "--enable-lzma" "--enable-iconv"
            "--enable-libx264" "--enable-libdav1d" "--enable-libopus"
            "--enable-libvorbis" "--enable-libmp3lame" "--enable-libzimg"
          ]
          # darwin can't take any "-static" linker flag (Apple ships
          # only libSystem.dylib — no libSystem.a, so the compiler probe
          # `cc -static main.c` aborts configure). On darwin we rely on
          # ld picking the dep .a's by preference and let libSystem stay
          # implicit-dynamic per docs/dynamic-link-policy.md. ffmpeg
          # reinterprets `--enable-static --disable-shared` as
          # LDFLAGS=-static internally (same trap that hit htop / tmux),
          # so omit those too on darwin.
          ++ (if isDarwin then [ ]
              else [ "--extra-ldflags=-static" "--enable-static" "--disable-shared" ])
          ++ extraConfigureFlags;
        in
        stdenv.mkDerivation {
          pname = "ffmpeg";
          inherit (pkgs.ffmpeg-headless) version src;

          # pkgsBuildHost is the canonical "build tools that target host"
          # scope:
          #   linux x86_64-linux native → x86_64-unknown-linux-musl-pkg-config
          #   mingw cross            → x86_64-w64-mingw32-pkg-config
          #   darwin x86_64-darwin cross from arm64-darwin
          #                          → x86_64-apple-darwin-pkg-config
          # ffmpeg's --cross-prefix=<triple>- derives a `<triple>-pkg-config`
          # binary that has to be on PATH; pkgsBuildHost.pkg-config is named
          # to match. `pkgs.buildPackages` picks the BUILD platform's wrapper
          # (wrong triple), and `pkgs.X` with no scope is static + unprefixed.
          # Also: pkgsBuildHost.perl is non-static (build-time tool) — `pkgs`
          # in cross-darwin-pkgsStatic gives perl-static which fails to build.
          nativeBuildInputs = with pkgs.pkgsBuildHost; [ pkg-config nasm yasm perl ];
          buildInputs = (with pkgs; [
            zlib bzip2 xz libiconv x264 libvorbis libogg lame zimg
          ]) ++ [
            (ulib.nativeFixes.libopus pkgs)
            (ulib.nativeFixes.dav1d pkgs)
          ] ++ extraInputs;

          strictDeps = true;
          enableParallelBuilding = true;
          stripAllList = [ "bin" ];

          configurePhase = ''
            runHook preConfigure
            # ffmpeg's `require_cpp_condition` for x264 trips on the
            # default x264.h header decoration; drop the check.
            sed -i '/X264_API_IMPORTS/d' configure
            ./configure ${builtins.concatStringsSep " " flags}
            runHook postConfigure
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp ffmpeg${exe} ffprobe${exe} $out/bin/
            runHook postInstall
          '';

          passthru = { pname = "ffmpeg"; inherit (pkgs.ffmpeg-headless) version; };
        };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "ffmpeg";

      # darwin's libSystem doesn't ship libpthread.a so --enable-pthreads
      # breaks the configure probe; linux is fine.
      build = pkgs: mkFfmpeg pkgs.pkgsStatic {
        extraConfigureFlags =
          if pkgs.stdenv.isDarwin then [ ] else [ "--enable-pthreads" ];
      };

      # mingw: force pthreads (not w32threads) to match downstream codec
      # libs (x264, dav1d) that were built against pthreads.
      windowsBuild = pkgs:
        let cross = ulib.mingwStaticCross pkgs; in
        mkFfmpeg cross {
          extraConfigureFlags = [ "--disable-w32threads" "--enable-pthreads" ];
          extraInputs = [ cross.windows.pthreads ];
        };
    };
}
