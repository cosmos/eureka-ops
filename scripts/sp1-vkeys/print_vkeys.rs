//! Prints the four SP1 ICS07 Tendermint program vkeys (bytes32) computed from the given ELF files.
//!
//! This reuses the upstream prover crate so the vkeys are computed the *exact* same way the relayer/proof-api
//! computes them at runtime — `sp1_sdk` mock `setup()` over the program ELF bytes (`get_vkey().bytes32()`,
//! see `packages/sp1-ics07-tendermint-prover/src/programs.rs` and `programs/operator/src/runners/genesis.rs`).
//! A vkey is a deterministic function of the ELF bytes, so running this over the *released* ELFs yields the
//! same values the deployed prover (which loads those same ELFs) will use — no running proof-api required.
//!
//! NOTE: This file is copied into `<solidity-ibc-eureka>/programs/operator/src/bin/` by
//! `eureka-ops/scripts/sp1-vkeys.sh`, built with that workspace's toolchain, then removed. It is not meant to
//! be committed into solidity-ibc-eureka.
//!
//! Usage: <bin> <update_client_elf> <membership_elf> <uc_and_membership_elf> <misbehaviour_elf>

use sp1_ics07_tendermint_prover::programs::{
    MembershipProgram, MisbehaviourProgram, SP1Program, UpdateClientAndMembershipProgram, UpdateClientProgram,
};
use sp1_sdk::HashableKey;
use std::{env, fs, process};

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.len() != 4 {
        eprintln!(
            "usage: print-vkeys <update_client_elf> <membership_elf> <uc_and_membership_elf> <misbehaviour_elf>"
        );
        process::exit(2);
    }

    let read = |p: &str| fs::read(p).unwrap_or_else(|e| panic!("failed to read ELF {p}: {e}"));

    let update_client = UpdateClientProgram::new(read(&args[0]));
    let membership = MembershipProgram::new(read(&args[1]));
    let uc_and_membership = UpdateClientAndMembershipProgram::new(read(&args[2]));
    let misbehaviour = MisbehaviourProgram::new(read(&args[3]));

    // get_vkey() runs the SP1 mock setup over the ELF on a dedicated thread; deterministic for fixed ELF bytes.
    println!(
        "{{\"updateClientVkey\":\"{}\",\"membershipVkey\":\"{}\",\"ucAndMembershipVkey\":\"{}\",\"misbehaviourVkey\":\"{}\"}}",
        update_client.get_vkey().bytes32(),
        membership.get_vkey().bytes32(),
        uc_and_membership.get_vkey().bytes32(),
        misbehaviour.get_vkey().bytes32()
    );
}
