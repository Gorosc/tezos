(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Proto_alpha
open Tezos_context

val inject_seed_nonce_revelation:
  #Client_rpcs.ctxt ->
  Client_proto_rpcs.block ->
  ?async:bool ->
  (Raw_level.t * Nonce.t) list ->
  Operation_hash.t tzresult Lwt.t

val forge_seed_nonce_revelation:
  Client_commands.full_context ->
  Client_proto_rpcs.block ->
  (Raw_level.t * Nonce.t) list ->
  unit tzresult Lwt.t
