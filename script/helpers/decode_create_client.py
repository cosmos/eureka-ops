#!/usr/bin/env python3
"""Decode trustedClientState + trustedConsensusStateHash from proof-api / relayer CreateClient calldata.

The proof-api `CreateClient` endpoint returns the SP1ICS07Tendermint *creation* calldata, i.e.
`<contract creation bytecode> ++ abi.encode(constructorArgs)`. The constructor is:

    constructor(
        bytes32 updateClientVkey,            # arg 0
        bytes32 membershipVkey,              # arg 1
        bytes32 ucAndMembershipVkey,         # arg 2
        bytes32 misbehaviourVkey,            # arg 3
        address sp1Verifier,                 # arg 4
        bytes   _clientState,                # arg 5  (the only dynamic arg)
        bytes32 _consensusState,             # arg 6  (consensus state HASH)
        address roleManager,                 # arg 7
    )

We do NOT know the creation-bytecode length and we must NOT assume it matches any locally compiled
contract (the running proof-api may be a different version). Instead we locate the appended ABI tuple
*structurally*: the args head is 8 words (256 bytes); arg 5's head word holds the offset to the dynamic
bytes, which is always 0x100 (256). We scan for the unique start offset whose internal structure and
length closure are self-consistent, so the result is independent of the contract/compiler version.

Usage: decode_create_client.py <0x-calldata>   (or pass via the CALLDATA env var)
Prints JSON: {"trustedClientState": "0x..", "trustedConsensusStateHash": "0x.."}
"""
import json
import os
import sys

WORD = 32
HEAD_WORDS = 8
HEAD_LEN = HEAD_WORDS * WORD  # 256
CLIENT_STATE_OFFSET = HEAD_LEN  # arg5 dynamic data begins right after the head


def _word(b, off):
    return int.from_bytes(b[off:off + WORD], "big")


def _roundup32(n):
    return (n + 31) // 32 * 32


def decode(calldata_hex):
    h = calldata_hex.strip()
    if h.startswith(("0x", "0X")):
        h = h[2:]
    cd = bytes.fromhex(h)
    n = len(cd)

    candidates = []
    # p = byte offset where the appended constructor-arg tuple begins
    for p in range(0, n - (HEAD_LEN + WORD) + 1):
        # arg5 (clientState) head word must be the offset 0x100
        if _word(cd, p + 5 * WORD) != CLIENT_STATE_OFFSET:
            continue
        # arg4 (sp1Verifier) and arg7 (roleManager) are addresses: top 12 bytes must be zero
        if cd[p + 4 * WORD: p + 4 * WORD + 12] != b"\x00" * 12:
            continue
        if cd[p + 7 * WORD: p + 7 * WORD + 12] != b"\x00" * 12:
            continue
        # length word of clientState sits right after the head; data follows, padded to 32, ending at n
        client_len = _word(cd, p + CLIENT_STATE_OFFSET)
        data_start = p + CLIENT_STATE_OFFSET + WORD
        if data_start + _roundup32(client_len) != n:
            continue
        client_state = cd[data_start:data_start + client_len]
        consensus_hash = cd[p + 6 * WORD: p + 7 * WORD]
        candidates.append((client_state, consensus_hash))

    if not candidates:
        raise ValueError("could not locate constructor args in calldata (unexpected CreateClient response)")
    if len(candidates) > 1:
        raise ValueError(f"ambiguous decode: found {len(candidates)} candidate arg layouts")
    client_state, consensus_hash = candidates[0]
    return "0x" + client_state.hex(), "0x" + consensus_hash.hex()


def main():
    calldata = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CALLDATA", "")
    if not calldata:
        sys.exit("usage: decode_create_client.py <0x-calldata>  (or set CALLDATA)")
    client_state, consensus_hash = decode(calldata)
    print(json.dumps({"trustedClientState": client_state, "trustedConsensusStateHash": consensus_hash}))


if __name__ == "__main__":
    main()
