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

      # ---------------------------------------------------------------------
      # Codec libs, parameterized by package set. Used by both native
      # (pkgsStatic) and Windows (mingwStaticCross). The stdenv-level
      # makeStaticLibraries adapter takes care of autotools/cmake/meson
      # libs (bzip2, xz, libiconv, libogg, libopus, lame, zimg, dav1d),
      # so they're inherited unmodified from `pkgs`.
      #
      # zlib and x264 escape that adapter (custom builders/configure);
      # their static fix lives in nix-lib's `applyPackageFix`, applied
      # here as a no-op under pkgsStatic.
      #
      # libvorbis on mingw needs its libogg input pinned: vorbis.pc
      # references libogg's pkgconfig dir, but cached cross libogg is
      # shared-by-default. Pin our static-cross libogg so vorbis
      # resolves against an .a.
      # ---------------------------------------------------------------------
      mkCodecLibs = pkgs:
        let
          isStatic = pkgs.stdenv.hostPlatform.isStatic or false;
        in
        rec {
          inherit (pkgs) bzip2 xz libiconv libogg libopus lame zimg dav1d;
          zlib = ulib.applyPackageFix pkgs "zlib" pkgs.zlib;
          x264 = ulib.applyPackageFix pkgs "x264" pkgs.x264;
          libvorbis =
            if isStatic
            then pkgs.libvorbis
            else pkgs.libvorbis.override { inherit libogg; };
        };

      # Common ffmpeg ./configure flags (shared by native + Windows).
      ffmpegConfigureCommon = ''
        --pkg-config=pkg-config \
        --pkg-config-flags=--static \
        --extra-ldflags=-static \
        --disable-doc \
        --disable-htmlpages \
        --disable-manpages \
        --disable-podpages \
        --disable-txtpages \
        --disable-debug \
        --disable-stripping \
        --enable-gpl \
        --enable-version3 \
        --enable-runtime-cpudetect \
        --enable-network \
        --disable-ffplay \
        --enable-ffmpeg \
        --enable-ffprobe \
        --enable-zlib \
        --enable-bzlib \
        --enable-lzma \
        --enable-iconv \
        --enable-libx264 \
        --enable-libdav1d \
        --enable-libopus \
        --enable-libvorbis \
        --enable-libmp3lame \
        --enable-libzimg
      '';
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "ffmpeg";

      # ---------------------------------------------------------------------
      # Native build: from-source ffmpeg via pkgsStatic. Bypassing
      # nixpkgs's pkgsStatic.ffmpeg-headless avoids its hardcoded
      # codec deps (openapv, ocl-icd, libtiff, libsndfile, ...) which
      # have their own pkgsStatic build issues. We list only the
      # codecs we actually want.
      # ---------------------------------------------------------------------
      build = pkgs:
        let
          static = mkCodecLibs pkgs.pkgsStatic;
          version = pkgs.ffmpeg-headless.version;
          ffmpegSrc = pkgs.ffmpeg-headless.src;
          isDarwin = pkgs.stdenv.isDarwin;
        in
        pkgs.pkgsStatic.stdenv.mkDerivation {
          pname = "ffmpeg";
          inherit version;
          src = ffmpegSrc;

          nativeBuildInputs = with pkgs; [
            pkg-config
            nasm
            yasm
            perl
          ];

          buildInputs = builtins.attrValues static;

          strictDeps = true;
          enableParallelBuilding = true;

          configurePhase = ''
            runHook preConfigure

            sed -i '/X264_API_IMPORTS/d' configure

            # pkgsStatic.stdenv.cc only ships prefixed binaries
            # (e.g. x86_64-unknown-linux-musl-gcc) — use --cross-prefix.
            # No ERR trap: ffmpeg's configure has its own probe failure
            # handling and trap intercepts internal non-zero exits.
            ./configure \
              --prefix=$out \
              --cross-prefix=${ulib.crossPrefix pkgs.pkgsStatic} \
              --host-cc=${pkgs.stdenv.cc}/bin/cc \
              --enable-cross-compile \
              --target-os=${if isDarwin then "darwin" else "linux"} \
              --arch=${pkgs.stdenv.hostPlatform.uname.processor} \
              --enable-static \
              --disable-shared \
              ${if isDarwin then "" else "--enable-pthreads \\"}
              ${ffmpegConfigureCommon}

            runHook postConfigure
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp ffmpeg ffprobe $out/bin/
            ${pkgs.pkgsStatic.stdenv.hostPlatform.config}-strip $out/bin/ffmpeg $out/bin/ffprobe
            runHook postInstall
          '';

          passthru = { pname = "ffmpeg"; inherit version; };
        };

      # ---------------------------------------------------------------------
      # Windows build: from-source ffmpeg cross-compiled via MinGW.
      # Same codec-libs strategy as native, sourced from mingwStaticCross
      # so every dep (autotools/cmake/meson) builds static-only via the
      # shared makeStaticLibraries adapter.
      # ---------------------------------------------------------------------
      windowsBuild = pkgs:
        let
          cross = ulib.mingwStaticCross pkgs;
          static = mkCodecLibs cross;
          version = pkgs.ffmpeg-headless.version;
          ffmpegSrc = pkgs.ffmpeg-headless.src;
        in
        cross.stdenv.mkDerivation {
          pname = "ffmpeg";
          inherit version;
          src = ffmpegSrc;

          nativeBuildInputs = with pkgs; [
            pkg-config
            nasm
            yasm
            perl
          ];

          buildInputs = (builtins.attrValues static) ++ [
            cross.windows.pthreads
          ];

          strictDeps = true;
          enableParallelBuilding = true;

          configurePhase = ''
            runHook preConfigure

            cleanup_on_fail() {
              echo "=== ffbuild/config.log (last 200 lines) ===" >&2
              tail -200 ffbuild/config.log >&2 || true
            }
            trap cleanup_on_fail ERR

            sed -i '/X264_API_IMPORTS/d' configure

            ./configure \
              --prefix=$out \
              --target-os=mingw64 \
              --arch=x86_64 \
              --cross-prefix=x86_64-w64-mingw32- \
              --enable-cross-compile \
              --host-cc=${pkgs.stdenv.cc}/bin/cc \
              --disable-w32threads \
              --enable-pthreads \
              --enable-static \
              --disable-shared \
              ${ffmpegConfigureCommon}

            runHook postConfigure
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            cp ffmpeg.exe ffprobe.exe $out/bin/
            x86_64-w64-mingw32-strip $out/bin/ffmpeg.exe $out/bin/ffprobe.exe
            runHook postInstall
          '';

          passthru = { pname = "ffmpeg"; inherit version; };

          meta = with pkgs.lib; {
            description = "FFmpeg headless, statically linked MinGW build";
            platforms = [ "x86_64-linux" ];
            mainProgram = "ffmpeg";
          };
        };
    };
}
