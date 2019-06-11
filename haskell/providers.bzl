"""Providers exposed by the Haskell rules."""

load(
    ":private/path_utils.bzl",
    "get_lib_name",
    "make_path",
    "mangle_static_library",
    "symlink_dynamic_library",
    "target_unique_name",
)

HaskellInfo = provider(
    doc = "Common information about build process: dependencies, etc.",
    fields = {
        "package_databases": "Depset of package cache files.",
        "version_macros": "Depset of version macro files.",
        "import_dirs": "Import hierarchy roots.",
        "source_files": "Depset of files that contain Haskell modules.",
        "extra_source_files": "Depset of non-Haskell source files.",
        "static_libraries": "Ordered collection of compiled library archives.",
        "dynamic_libraries": "Depset of dynamic libraries.",
        "interface_dirs": "Depset of interface dirs belonging to the packages.",
        "compile_flags": "Arguments that were used to compile the code.",
    },
)

HaskellLibraryInfo = provider(
    doc = "Library-specific information.",
    fields = {
        "package_id": "Workspace unique package identifier.",
        "version": "Package version.",
    },
)

HaskellCoverageInfo = provider(
    doc = "Information about coverage instrumentation for Haskell files.",
    fields = {
        "coverage_data": "A list of coverage data containing which parts of Haskell source code are being tracked for code coverage.",
    },
)

HaddockInfo = provider(
    doc = "Haddock information.",
    fields = {
        "package_id": "Package id, usually of the form name-version.",
        "transitive_html": "Dictionary from package id to html dirs.",
        "transitive_haddocks": "Dictionary from package id to Haddock files.",
    },
)

HaskellLintInfo = provider(
    doc = "Provider that collects files produced by linters",
    fields = {
        "outputs": "Set of linter log files.",
    },
)

HaskellProtobufInfo = provider(
    doc = "Provider that wraps providers of auto-generated Haskell libraries",
    fields = {
        "files": "files",
    },
)

C2hsLibraryInfo = provider(
    doc = "Information about c2hs dependencies.",
    fields = {
        "chi_file": "c2hs interface file",
        "import_dir": "Import directory containing generated Haskell source file.",
    },
)

GhcPluginInfo = provider(
    doc = "Encapsulates GHC plugin dependencies and tools",
    fields = {
        "module": "Plugin entrypoint.",
        "deps": "Plugin dependencies.",
        "args": "Plugin options.",
        "tools": "Plugin tools.",
    },
)

def _min_lib_to_link(a, b):
    """Return the smaller of two LibraryToLink objects.

    Determined by component-wise comparison.
    """
    a_tuple = (
        a.dynamic_library,
        a.interface_library,
        a.static_library,
        a.pic_static_library,
    )
    b_tuple = (
        b.dynamic_library,
        b.interface_library,
        b.static_library,
        b.pic_static_library,
    )
    if a_tuple < b_tuple:
        return a
    else:
        return b

def _get_unique_lib_files(cc_info):
    """Deduplicate library dependencies.

    This function removes duplicate filenames in the list of library
    dependencies to avoid clashes when creating symlinks. Such duplicates can
    occur due to dependencies on haskell_toolchain_library targets which each
    duplicate their core library dependencies. See
    https://github.com/tweag/rules_haskell/issues/917.

    This function preserves correct static linking order.

    This function is deterministic in which LibraryToLink is chosen as the
    unique representative independent of their order of appearance.

    Args:
      cc_info: Combined CcInfo provider of dependencies.

    Returns:
      List of LibraryToLink: list of unique libraries to link.
    """
    libs_to_link = cc_info.linking_context.libraries_to_link

    # This is a workaround for duplicated libraries due to
    # haskell_toolchain_library dependencies. See
    # https://github.com/tweag/rules_haskell/issues/917
    libs_by_filename = {}
    filenames = []
    for lib_to_link in libs_to_link:
        if lib_to_link.dynamic_library:
            lib = lib_to_link.dynamic_library
        elif lib_to_link.interface_library:
            lib = lib_to_link.interface_library
        elif lib_to_link.static_library:
            lib = lib_to_link.static_library
        elif lib_to_link.pic_static_library:
            lib = lib_to_link.pic_static_library
        else:
            fail("Empty CcInfo.linking_context.libraries_to_link entry.")
        prev = libs_by_filename.get(lib.basename)
        if prev:
            # To be deterministic we always use File that compares smaller.
            # This is so that this function can be used multiple times for the
            # same target without generating conflicting actions. E.g. for the
            # compilation step as well as the runghc generation step.
            libs_by_filename[lib.basename] = _min_lib_to_link(prev, lib_to_link)
        else:
            libs_by_filename[lib.basename] = lib_to_link
        filenames.append(lib.basename)

    # Deduplicate the library names. Make sure to preserve static linking order.
    filenames = depset(
        transitive = [depset(direct = [filename]) for filename in filenames],
        order = "topological",
    ).to_list()

    return [
        libs_by_filename[filename]
        for filename in filenames
    ]

def get_ghci_extra_libs(hs, cc_info, dynamic = True, path_prefix = None):
    """Get libraries appropriate for GHCi's linker.

    GHC expects dynamic and static versions of the same library to have the
    same library name. Static libraries for which this is not the case will be
    symlinked to a matching name.

    Furthermore, dynamic libraries will be symbolically linked into a common
    directory to allow for less RPATH entries and to fix file extensions that
    GHCi does not support.

    GHCi can load PIC static libraries (-fPIC -fexternal-dynamic-refs) and
    dynamic libraries. Preferring static libraries can be useful to reduce the
    risk of exceeding the MACH-O header size limit on macOS, and to reduce
    build times by avoiding to generate dynamic libraries. However, this
    requires GHCi to run with the statically linked rts library.

    Args:
      hs: Haskell context.
      cc_info: Combined CcInfo provider of dependencies.
      dynamic: (optional) Whether to prefer dynamic libraries.
      path_prefix: (optional) Prefix for the entries in the generated library path.

    Returns:
      (libs, ghc_env):
        libs: depset of File, the libraries that should be passed to GHCi.
        ghc_env: dict, environment variables to set for GHCi.

    """
    fixed_lib_dir = target_unique_name(hs, "_ghci_libs")
    libs_to_link = _get_unique_lib_files(cc_info)
    libs = []
    for lib_to_link in libs_to_link:
        dynamic_lib = None
        if lib_to_link.dynamic_library:
            dynamic_lib = lib_to_link.dynamic_library
        elif lib_to_link.interface_library:
            # XXX: Do these work with GHCi?
            dynamic_lib = lib_to_link.interface_library
        static_lib = None
        if lib_to_link.pic_static_library:
            static_lib = lib_to_link.pic_static_library
        elif lib_to_link.static_library and hs.toolchain.is_windows:
            # NOTE: GHCi cannot load non-PIC static libraries, except on Windows.
            static_lib = lib_to_link.static_library

        if dynamic_lib:
            dynamic_lib = symlink_dynamic_library(hs, dynamic_lib, fixed_lib_dir)
        static_lib = mangle_static_library(hs, dynamic_lib, static_lib, fixed_lib_dir)

        lib = static_lib if static_lib else dynamic_lib
        if dynamic and dynamic_lib:
            lib = dynamic_lib

        if lib:
            libs.append(lib)

    # NOTE: We can avoid constructing these in the future by instead generating
    #   a dedicated package configuration file defining the required libraries.
    sep = ";" if hs.toolchain.is_windows else None
    library_path = make_path(libs, prefix = path_prefix, sep = sep)
    ghc_env = {
        "LIBRARY_PATH": library_path,
        "LD_LIBRARY_PATH": library_path,
    }

    return (depset(direct = libs), ghc_env)

def get_extra_libs(hs, dynamic, cc_info):
    """Get libraries appropriate for linking with GHC.

    GHC expects dynamic and static versions of the same library to have the
    same library name. Static libraries for which this is not the case will be
    symlinked to a matching name.

    Furthermore, dynamic libraries will be symbolically linked into a common
    directory to allow for less RPATH entries.

    Args:
      hs: Haskell context.
      dynamic: Whether to prefer dynamic libraries.
      cc_info: Combined CcInfo provider of dependencies.

    Returns:
      depset of File: the libraries that should be passed to GHC for linking.

    """
    fixed_lib_dir = target_unique_name(hs, "_libs")
    libs_to_link = _get_unique_lib_files(cc_info)
    static_libs = []
    dynamic_libs = []
    for lib_to_link in libs_to_link:
        dynamic_lib = None
        if lib_to_link.dynamic_library:
            dynamic_lib = lib_to_link.dynamic_library
        elif lib_to_link.interface_library:
            dynamic_lib = lib_to_link.interface_library
        static_lib = None
        if lib_to_link.pic_static_library:
            static_lib = lib_to_link.pic_static_library
        elif lib_to_link.static_library:
            static_lib = lib_to_link.static_library

        if dynamic_lib:
            dynamic_lib = symlink_dynamic_library(hs, dynamic_lib, fixed_lib_dir)
        static_lib = mangle_static_library(hs, dynamic_lib, static_lib, fixed_lib_dir)

        if dynamic and dynamic_lib:
            dynamic_libs.append(dynamic_lib)
        elif not static_lib:
            dynamic_libs.append(dynamic_lib)
        else:
            static_libs.append(static_lib)

    static_libs = depset(direct = static_libs)
    dynamic_libs = depset(direct = dynamic_libs)
    return (static_libs, dynamic_libs)
