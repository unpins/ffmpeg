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
            "--host-cc=${pkgs.buildPackages.stdenv.cc}/bin/cc"
            "--enable-cross-compile"
            "--target-os=${targetOs}"
            "--arch=${stdenv.hostPlatform.uname.processor}"
            # ffmpeg's configure auto-derives pkg-config as
            # `${cross_prefix}pkg-config` — the binary the wrapper
            # actually ships. Don't pass `--pkg-config=pkg-config`
            # or it looks for a bare `pkg-config` that isn't in PATH.
            "--pkg-config-flags=--static"
            "--enable-static" "--disable-shared"
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
          # On darwin, `-extra-ldflags=-static` makes ffmpeg's compiler
          # probe link `cc -static main.c` which fails because Apple
          # ships only libSystem.dylib (no libSystem.a). The dep .a's
          # are still picked from pkgsStatic by ld preference; libSystem
          # stays implicit-dynamic per the catalog's darwin policy
          # (docs/dynamic-link-policy.md). Linux/mingw require `-static`
          # to force the final link.
          ++ (if isDarwin then [ ] else [ "--extra-ldflags=-static" ])
          ++ extraConfigureFlags;
        in
        stdenv.mkDerivation {
          pname = "ffmpeg";
          inherit (pkgs.ffmpeg-headless) version src;

          nativeBuildInputs = with pkgs.buildPackages; [ pkg-config nasm yasm perl ];
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
