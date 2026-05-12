{
  description = "Standalone build of ffmpeg (headless)";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    unpins-lib.url = "github:unpins/nix-lib/v1";
  };

  outputs = { self, nixpkgs, unpins-lib }:
    let
      lib = nixpkgs.lib;
      ulib = unpins-lib.lib;

      # allowUnsupportedSystem: pkgsStatic.libpulseaudio's meta.platforms
      # excludes x86_64-linux. We never depend on it (withPulse is false)
      # but the platform check fires during eval before dep culling.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnsupportedSystem = true;
      };

      # ---------------------------------------------------------------------
      # Codec libs static-flipped, parameterized by package set.
      # Used by both native (pkgsStatic) and Windows (pkgsCross.mingwW64).
      # Helpers from `unpins-lib`: keepStatic* are cache-aware no-ops
      # under pkgsStatic so cache.nixos.org hits are preserved.
      #
      # x264.pc fix is applied always — nixpkgs packaging decision
      # independent of static/shared, breaks ffmpeg's static link probe.
      # ---------------------------------------------------------------------
      mkCodecLibs = pkgs:
        let
          isStatic = pkgs.stdenv.hostPlatform.isStatic or false;
        in
        rec {
          zlib       = ulib.keepStaticZlib  pkgs pkgs.zlib;
          bzip2      = ulib.keepStaticAuto  pkgs pkgs.bzip2;
          xz         = ulib.keepStaticAuto  pkgs pkgs.xz;
          libiconv   = ulib.keepStaticAuto  pkgs pkgs.libiconv;
          libogg     = ulib.keepStaticCmake pkgs [] pkgs.libogg;
          libvorbis  =
            if isStatic
            then pkgs.libvorbis
            # Cross-mingw: pin our static libogg so vorbis.pc resolves
            # to the libogg whose lib/ has libogg.a.
            else ulib.keepStaticAuto pkgs (pkgs.libvorbis.override {
              inherit libogg;
            });
          libopus    = ulib.keepStaticMeson pkgs pkgs.libopus;
          lame       = ulib.keepStaticAuto  pkgs pkgs.lame;
          zimg       = ulib.keepStaticAuto  pkgs pkgs.zimg;
          # x264 always needs the .pc patch. For non-static, also force
          # static-only build (otherwise x264.h's `__declspec(dllimport)`
          # makes ffmpeg link probe look for `__imp_x264_*`).
          x264       = pkgs.x264.overrideAttrs (old: {
            configureFlags = (old.configureFlags or [])
              ++ lib.optionals (!isStatic)
                [ "--enable-static" "--disable-shared" "--enable-pic" ];
            postFixup = (old.postFixup or "") + ''
              for d in "$dev" "$out"; do
                pc="$d/lib/pkgconfig/x264.pc"
                [ -f "$pc" ] && sed -i 's| -DX264_API_IMPORTS||g' "$pc" || true
              done
            '';
          });
          dav1d      = ulib.keepStaticMeson pkgs pkgs.dav1d;
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

      # ---------------------------------------------------------------------
      # Native build: from-source ffmpeg via pkgsStatic. Bypassing
      # nixpkgs's pkgsStatic.ffmpeg-headless avoids its hardcoded
      # codec deps (openapv, ocl-icd, libtiff, libsndfile, ...) which
      # have their own pkgsStatic build issues. We list only the
      # codecs we actually want.
      # ---------------------------------------------------------------------
      mkNative = system:
        let
          pkgs = pkgsFor system;
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
      # Same codec-libs strategy as native, just sourced from
      # pkgsCross.mingwW64 instead of pkgsStatic.
      # ---------------------------------------------------------------------
      mkWindows = buildSystem:
        let
          pkgs = import nixpkgs {
            system = buildSystem;
            config.allowUnsupportedSystem = true;
          };
          cross = pkgs.pkgsCross.mingwW64;
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

          meta = with lib; {
            description = "FFmpeg headless, statically linked MinGW build";
            platforms = [ "x86_64-linux" ];
            mainProgram = "ffmpeg";
          };
        };
    in
    {
      packages = lib.recursiveUpdate
        (ulib.forAllNative (system: { default = mkNative system; }))
        {
          x86_64-linux."windows-x86_64" = mkWindows "x86_64-linux";
        };

      apps = ulib.forAllNative (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/ffmpeg";
        };
      });
    };
}
