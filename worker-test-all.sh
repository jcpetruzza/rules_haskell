#!/bin/bash
bazel test -k --strategy=HaskellLinkDynamicLibrary=worker --strategy=HaskellBuildLibrary=worker --strategy=HaskellBuildBinary=worker --strategy=HaskellLinkBinary=worker --worker_sandboxing //...
# --test_verbose_timeout_warnings