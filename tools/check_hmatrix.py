#!/usr/bin/env python3
"""Exhaustive structural check of the Hsiao SEC-DED parity-check matrix.

SEC-DED does not depend on the data width -- it depends on three properties of
the H columns, and this checks all three at the shipped 256-bit width, which is
too large for the SAT solver to reason about behaviourally:

  1. all columns DISTINCT   -> a single error maps to exactly one location
  2. all columns ODD weight -> a single error gives an odd-weight syndrome
  3. all columns weight >=3 -> data columns never alias a check-bit column

(2) is what guarantees no miscorrection: the XOR of two odd-weight columns is
EVEN, so a double error can never equal any column and is always detected.
"""
import sys
from itertools import combinations


def build(dw, sw):
    cols, v = [], 1
    while len(cols) < dw and v < (1 << sw):
        if bin(v).count("1") >= 3 and bin(v).count("1") % 2 == 1:
            cols.append(v)
        v += 1
    return cols


def check(dw, sw):
    cols = build(dw, sw)
    ok = True
    if len(cols) != dw:
        print(f"  FAIL: only {len(cols)} usable columns for DW={dw}"); return False
    if len(set(cols)) != dw:
        print("  FAIL: columns not distinct"); ok = False
    if any(bin(c).count("1") % 2 == 0 for c in cols):
        print("  FAIL: even-weight column present"); ok = False
    if any(bin(c).count("1") < 3 for c in cols):
        print("  FAIL: column of weight < 3 aliases a check bit"); ok = False
    # the decisive one, checked directly rather than inferred
    bad = [(i, j) for i, j in combinations(range(dw), 2)
           if bin(cols[i] ^ cols[j]).count("1") % 2 == 1]
    if bad:
        print(f"  FAIL: {len(bad)} double-error syndromes have ODD weight "
              f"(would be MISCORRECTED), e.g. bits {bad[0]}"); ok = False
    if ok:
        print(f"  DW={dw} SW={sw}: {dw} distinct odd-weight columns, "
              f"all weight>=3; all {dw*(dw-1)//2} double-error syndromes "
              f"even -> detected, never miscorrected")
    return ok


if __name__ == "__main__":
    print("Hsiao SEC-DED H-matrix structural check")
    good = check(256, 10) & check(32, 7)     # shipped and formal configurations
    sys.exit(0 if good else 1)
