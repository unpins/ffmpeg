# Windows (mingw) fold: ffmpeg + ffprobe into one `ffmpeg.exe`.
#
# On linux/darwin the unpin-llvm engine self-folds the two programs from their
# bitcode modules. mingw is off-engine (gcc cross), so there is no module and no
# fold — the build installs two `.exe` and `unpinEmbedWrap` ships only the
# primary, i.e. ffprobe silently disappeared from the Windows artifact.
#
# Mechanics — the cpp-rename ("X+Z") recipe, same family as nix-lib's
# `cppRenameMulticall`:
#
#   * Each program's OBJS come from ffmpeg's OWN build system (`make` prints
#     `$(OBJS-<prog>)`), so the object list tracks the version rather than a
#     frozen copy of fftools/Makefile.
#
#   * Only `fftools/**` is renamed, and PER PROGRAM: each gets a private
#     recompile of cmdutils.o/opt_common.o/textformat/*.o behind its own
#     `-include <prog>.rename.h`. Those shared objects call back into the
#     program by name (`show_help_default`, `program_name`), so a per-program
#     copy is what keeps each callback bound to ITS program rather than to
#     whichever copy won the link.
#
#   * RECOMPILE, not `objcopy --redefine-syms`. On PE, gcc reaches a global
#     through a `.refptr.<sym>` COMDAT; objcopy renames <sym> and the
#     relocation inside the refptr, but the refptr's own name is not an
#     identifier and stays put — so both programs keep an identically named
#     COMDAT, the linker folds them, and one program reads the other's global.
#     (Observed exactly that: `ffprobe -version` printed ffmpeg's
#     `program_name` while ffprobe's own usage line printed ffprobe's.) Naming
#     the refptr in the rename map instead breaks the COMDAT association and
#     the definition goes undefined; `ld -r` + `--keep-global-symbol` links but
#     the second program faults at runtime. Renaming in the preprocessor sidesteps
#     all of it: gcc derives the refptr name from the already-renamed symbol.
#
#   * `compat/**` is deliberately NOT renamed and linked ONCE. Those objects are
#     libc replacements (`strtod`, win32 atomics) that libav*.a resolves under
#     their canonical names; namespacing them would silently re-point libavutil
#     at msvcrt's version. `fftools/fftoolsres.o` is also linked once — it
#     carries the Windows application manifest, and one copy per program makes
#     ld abort with ".rsrc merge failure: multiple non-default manifests".
#
#   * The final link reuses ffmpeg's own `$(call LINK,…)` with its `LDFLAGS`/
#     `FF_EXTRALIBS`, so the C++-runtime routing (LINK picks `$(LDXX)` when
#     `-lstdc++` is present — x265 puts it there) and the mingw `-static` flags
#     are exactly the ones the normal link would have used.
#
# Aliases and man are NOT embedded here: `unpinEmbedWrap` (mkStandaloneFlake)
# harvests `bin/ffprobe` as an alias and embeds the curated man set, as the
# single post-build embed.
{ lib }:
{ pkgs, ffmpeg, name ? "ffmpeg", programs ? [ "ffmpeg" "ffprobe" ] }:
let
  progList = lib.concatStringsSep " " programs;
  # printf format string: `\t`/`\n` stay as two-char escapes for printf to expand.
  appletLines = lib.concatMapStringsSep "\\n" (p: "${p}\\t${p}") programs;
  aliases = lib.filter (p: p != name) programs;

  argvFix = pkgs.writeText "unpin-argv-fix.c" ''
    if (win32_argc > 1 && !strncmp(win32_argv_utf8[1], "--unpin-program=", 16)) {
        memmove(&win32_argv_utf8[1], &win32_argv_utf8[2],
                sizeof(char *) * (size_t)(win32_argc - 1));
        win32_argc--;
    }
  '';

  # `$*` is the program name; UNPIN_OBJS/UNPIN_BIN come in on the command line.
  # LD_O is unusable here ($@ is the phony target), so name the output.
  multicallMk = pkgs.writeText "unpin-multicall.mk" ''
    .PHONY: unpin-objs-% unpin-multicall-link
    unpin-objs-%:
    ''\t@echo $(OBJS-$*)
    unpin-multicall-link:
    ''\t$(call LINK,$(LDFLAGS) ${
      lib.concatMapStringsSep " " (p: "$(LDFLAGS-${p})") programs} $(LDEXEFLAGS) -o multicall/$(UNPIN_BIN) $(UNPIN_OBJS) $(FF_EXTRALIBS) ${
      lib.concatMapStringsSep " " (p: "$(EXTRALIBS-${p})") programs})
  '';
in
ffmpeg.overrideAttrs (oa: {
  pname = "${oa.pname or "ffmpeg"}-multi";

  # `<bin> --unpin-program=<prog>` is the multitool form every unpins multicall
  # binary answers to. It works by argv surgery in the dispatcher — which
  # Windows throws away: under `HAVE_COMMANDLINETOARGVW` both tools call
  # `prepare_app_arguments()`, which REBUILDS argv from `GetCommandLineW()` and
  # ignores the argv main was handed. The selected applet then re-reads the raw
  # command line, sees the selector as an option, and dies with "Missing
  # argument for option '-unpin-program=…'". Drop the token the dispatcher
  # already consumed. (The argv[0] alias form never needed this.)
  #
  # Inserted as a FILE after a one-line anchor: a multi-line `--replace-fail`
  # pattern loses its inner indentation to the `''`-string de-indent, and there
  # is no unique single-line pattern that carries the whole snippet.
  # Every fftools program includes cmdutils.h, which `#undef main` to fend off
  # SDL's `#define main SDL_main` — and, since it lands AFTER our `-include`,
  # takes the rename of `main` down with it. Skip it only for the objects being
  # folded; outside the fold (ffplay + SDL) upstream behaviour is untouched.
  postPatch = (oa.postPatch or "") + ''
    grep -q 'win32_argv_utf8\[i\] = NULL;' fftools/cmdutils.c \
      || { echo "multicall: prepare_app_arguments anchor not found" >&2; exit 1; }
    sed -i '/win32_argv_utf8\[i\] = NULL;/r ${argvFix}' fftools/cmdutils.c

    grep -q '^#undef main' fftools/cmdutils.h \
      || { echo "multicall: cmdutils.h '#undef main' anchor not found" >&2; exit 1; }
    sed -i 's|^#undef main .*|#ifndef UNPIN_MULTICALL\n&\n#endif|' fftools/cmdutils.h
  '';

  postBuild = (oa.postBuild or "") + ''
    mkdir -p multicall
    install -m644 ${multicallMk} unpin-multicall.mk
    mk() { make --no-print-directory -f Makefile -f unpin-multicall.mk "$@"; }
    _unpin_orig_cflags=''${NIX_CFLAGS_COMPILE:-}
    objs() { tr '\n' ' ' < "multicall/$1.objs"; }

    : > multicall/shared.objs
    for p in ${progList}; do
      mk unpin-objs-$p | tr ' ' '\n' | grep -v '^$' > multicall/$p.all
      grep '^fftools/' multicall/$p.all | grep -v '^fftools/fftoolsres\.o$' \
        > multicall/$p.objs
      grep -v '^fftools/' multicall/$p.all >> multicall/shared.objs || true
      grep '^fftools/fftoolsres\.o$' multicall/$p.all >> multicall/shared.objs || true
    done
    sort -u multicall/shared.objs -o multicall/shared.objs

    # Phase A — discover each program's defined globals from the ORIGINAL
    # objects, before any recompile can perturb them, and emit its header.
    for p in ${progList}; do
      {
        echo "/* unpin multicall rename header: $p */"
        echo "#define UNPIN_MULTICALL 1"
        echo "#define main ''${p}_main"
        # `main` is the one function ffmpeg's -Werror=missing-prototypes
        # exempts; once renamed it needs a real declaration.
        echo "int ''${p}_main(int, char **);"
        $NM --defined-only -g $(objs $p) 2>/dev/null \
          | awk -v t="$p" '
              $2 ~ /^[TBDRWVCS]$/ {
                sym = $3
                if (sym ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && sym != "main" && !seen[sym]++)
                  print "#define " sym " " t "__" sym
              }'
      } > multicall/$p.rename.h
    done

    # Phase B — rebuild each program's objects behind its header and stash them
    # privately: the two programs share source paths, so a program's objects
    # must be copied out before the next program's rebuild clobbers them.
    for p in ${progList}; do
      rm -f $(objs $p)
      env NIX_CFLAGS_COMPILE="$_unpin_orig_cflags -include $PWD/multicall/$p.rename.h" \
        make --no-print-directory -j''${NIX_BUILD_CORES:-1} $(objs $p)
      mkdir -p multicall/obj_$p
      while IFS= read -r o; do
        cp "$o" "multicall/obj_$p/$(echo "$o" | tr / _)"
      done < multicall/$p.objs
      # Materialise before grepping: `nm … | grep -q` exits at the first match,
      # nm takes SIGPIPE, and the stdenv's `set -o pipefail` reports THAT — the
      # check would fail precisely when the symbol IS there.
      $NM --defined-only -g "multicall/obj_$p/fftools_$p.o" > multicall/$p.entry
      grep -q " ''${p}_main$" multicall/$p.entry \
        || { echo "multicall: $p entry point missing after rename; defined here:" >&2
             head -20 multicall/$p.entry >&2; exit 1; }
      echo "multicall: $p — $(wc -l < multicall/$p.objs) objs, $(wc -l < multicall/$p.rename.h) renames"
    done

    # No two programs may still share a defined global. ffmpeg's mingw LDFLAGS
    # carry `-Wl,--allow-multiple-definition` (needed for librsvg's rust
    # compiler_builtins vs libgcc), so a leaked symbol would NOT fail the link —
    # it would silently bind one program's shared objects to the other's copy.
    # Compiler-generated `.`-prefixed COMDAT aliases are excluded: the ones that
    # matter are named after a renamed symbol, so checking the symbols is enough.
    for p in ${progList}; do
      $NM --defined-only -g multicall/obj_$p/*.o \
        | awk '$2 ~ /^[TBDRWVCS]$/ && $3 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ { print $3 }' \
        | sort -u > multicall/$p.defs
    done
    sort multicall/*.defs | uniq -d > multicall/clash.syms
    if [ -s multicall/clash.syms ]; then
      echo "multicall: programs still share $(wc -l < multicall/clash.syms) defined globals after rename:" >&2
      head -40 multicall/clash.syms >&2
      exit 1
    fi

    printf '${appletLines}\n' > multicall/applets.list
  ${lib.multicallTableDispatcherC { inherit name; }}
    $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

    mk UNPIN_BIN=${name}.exe \
       UNPIN_OBJS="multicall/dispatcher.o multicall/obj_*/*.o $(tr '\n' ' ' < multicall/shared.objs)" \
       unpin-multicall-link
  '';

  # The base installPhase copied one `.exe` per program; ship the folded one and
  # leave `ffprobe` as a plain symlink for unpinEmbedWrap's alias harvest.
  postInstall = (oa.postInstall or "") + ''
    install -m755 multicall/${name}.exe "$out/bin/${name}.exe"
    ${lib.concatMapStringsSep "\n    " (a: ''
      rm -f "$out/bin/${a}.exe"
      ln -s "${name}.exe" "$out/bin/${a}"
    '') aliases}
  '';
})
