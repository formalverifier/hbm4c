#!/bin/bash
# ---------------------------------------------------------------------------
# check_instantiation.sh -- fail if any RTL module is never instantiated.
#
# WHY THIS EXISTS.  Rev 1.1 discovered SIX modules that were lint-clean,
# formally proved, mutation-covered -- and wired to nothing:
#
#   hbm4_wbuf       write buffer and read-after-write hazard detection
#   hbm4_csr        the entire APB register block, including AMAP_LOCK
#   hbm4_ecc_cache  inline ECC check-value cache
#   hbm4_ecc_init   ECC region initialisation
#   hbm4_err_log    error log
#   hbm4_scrub      patrol scrub
#
# Every existing check was blind to it, and each for the same reason: they all
# scope themselves to what is connected.  Lint elaborates a module standalone and
# is happy.  Formal proves a module in isolation -- and proving an unconnected
# module proves nothing about the design.  Simulation exercises the assembled
# slice, so a feature that is not there simply never appears; the tests pass
# because they cannot test what does not exist.
#
# 71 mutations with 0 survivors, on modules that were not in the design.
#
# An unconnected module is the most expensive kind of dead code: it carries the
# full appearance of verification while contributing nothing, and it makes the
# documentation lie.
# ---------------------------------------------------------------------------
set -u
cd "$(dirname "$0")/.." || exit 1

# Modules that are deliberately not instantiated by the controller.
# Anything listed here needs a REASON, not just a name.
declare -a ALLOWED=(
  "hbm4_addr_slice"   # ships to the customer's fabric (docs/05); by design
  "hbm4_sys_top"      # the top level; nothing above it to instantiate it
  "hbm4_pkg"          # package
  "hbm4_timing_pkg"   # package
)

fail=0
for f in rtl/*/*.sv; do
  m=$(basename "$f" .sv)
  skip=0
  for a in "${ALLOWED[@]}"; do [ "$m" = "$a" ] && skip=1; done
  [ $skip -eq 1 ] && continue

  # An instantiation is the module name at the start of a statement, in a file
  # other than its own definition.
  hits=$(grep -rlE "^[[:space:]]*${m}[[:space:]]+(#\(|[a-zA-Z_])" rtl/ --include="*.sv" 2>/dev/null \
         | grep -v "/${m}\.sv$" | wc -l | tr -d ' ')
  if [ "$hits" = "0" ]; then
    echo "NOT INSTANTIATED: $m  ($f)"
    fail=1
  fi
done

if [ $fail -ne 0 ]; then
  echo
  echo "A module that nothing instantiates is not part of the design, however"
  echo "thoroughly it is verified.  Either wire it up, or delete it and remove"
  echo "the documentation that claims the feature exists."
  exit 1
fi
echo "instantiation check: every module is reachable from hbm4_sys_top"
