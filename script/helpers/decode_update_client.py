#!/usr/bin/env python3
"""Extract the SP1Proof (vKey, publicValues, proof) from a proof-api UpdateClient `tx`.

The proof-api `UpdateClient` RPC returns the raw calldata to submit on the destination
chain. For an Ethereum ICS26Router that is `updateClient(string clientId, bytes updateMsg)`
(selector 0x6fbf8079); some deployments submit straight to the light client as
`updateClient(bytes updateMsg)` (selector 0x0bece356). In both cases `updateMsg` is
`abi.encode(IUpdateClientMsgs.MsgUpdateClient)`, and MsgUpdateClient wraps a single
`ISP1Msgs.SP1Proof { bytes32 vKey; bytes publicValues; bytes proof; }`.

We decode it structurally (no contract-version dependency): strip the 4-byte selector,
locate the `updateMsg` bytes arg, then read the SP1Proof tuple inside it. The result is the
exact triple `SP1ICS07Tendermint._verifySP1Proof` hands to `VERIFIER.verifyProof(...)`.

Usage: decode_update_client.py <0x-calldata>   (or pass via CALLDATA env var)
Prints JSON: {vKey, publicValues, proof, selector}  (selector = first 4 bytes of `proof`).
"""
import json
import os
import sys

WORD = 32

UPDATE_STRING_BYTES = "6fbf8079"  # updateClient(string,bytes)
UPDATE_BYTES = "0bece356"          # updateClient(bytes)


def _w(b, off):  # word as int
    return int.from_bytes(b[off:off + WORD], "big")


def _bytes_at(b, base, rel_off):
    """Read a dynamic `bytes` whose head word (an offset relative to `base`) sits at base+rel_off."""
    p = base + _w(b, base + rel_off)
    ln = _w(b, p)
    start = p + WORD
    return b[start:start + ln]


def decode(calldata_hex):
    h = calldata_hex.strip()
    if h.lower().startswith("0x"):
        h = h[2:]
    cd = bytes.fromhex(h)

    sel = cd[:4].hex()
    args = cd[4:]
    if sel == UPDATE_STRING_BYTES:
        # head: [offset(clientId string)] [offset(updateMsg bytes)]
        update_msg = _bytes_at(args, 0, WORD)          # second arg
    elif sel == UPDATE_BYTES:
        update_msg = _bytes_at(args, 0, 0)             # only arg
    else:
        # Unknown wrapper: assume the whole arg blob IS the abi-encoded MsgUpdateClient.
        update_msg = args

    # updateMsg = abi.encode(MsgUpdateClient). MsgUpdateClient{SP1Proof} and SP1Proof{bytes32,bytes,bytes}
    # are BOTH dynamic, so the encoding nests TWO offsets: w(0) -> the MsgUpdateClient tuple, then a
    # relative head word -> the SP1Proof tuple. (A single-level decode silently reads that inner offset
    # word as the vKey -- verified against a real reserved-cluster proof, which only decodes correctly
    # with the double dereference below.) SP1Proof = (bytes32 vKey, bytes publicValues, bytes proof).
    l1 = _w(update_msg, 0)                              # -> MsgUpdateClient tuple
    base = l1 + _w(update_msg, l1)                       # -> SP1Proof tuple
    vkey = update_msg[base:base + WORD]
    public_values = _bytes_at(update_msg, base, WORD)   # 2nd field of the tuple
    proof = _bytes_at(update_msg, base, 2 * WORD)        # 3rd field of the tuple

    return {
        "vKey": "0x" + vkey.hex(),
        "publicValues": "0x" + public_values.hex(),
        "proof": "0x" + proof.hex(),
        "selector": "0x" + proof[:4].hex(),
        "wrapper": "0x" + sel,
    }


def main():
    calldata = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CALLDATA", "")
    if not calldata:
        sys.exit("usage: decode_update_client.py <0x-calldata>  (or set CALLDATA)")
    print(json.dumps(decode(calldata)))


if __name__ == "__main__":
    main()
