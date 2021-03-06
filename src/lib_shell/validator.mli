(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

(** Tezos Shell - Main entry point of the validation scheduler. *)

type t

val create:
  State.t ->
  Distributed_db.t ->
  Peer_validator.limits ->
  Block_validator.limits ->
  Prevalidator.limits ->
  Net_validator.limits ->
  t Lwt.t
val shutdown: t -> unit Lwt.t

(** Start the validation scheduler of a given network. *)
val activate:
  t ->
  ?max_child_ttl:int ->
  State.Net.t -> Net_validator.t Lwt.t

type error +=
  | Inactive_network of Net_id.t
val get: t -> Net_id.t -> Net_validator.t tzresult Lwt.t
val get_exn: t -> Net_id.t -> Net_validator.t Lwt.t

(** Force the validation of a block. *)
val validate_block:
  t ->
  ?force:bool ->
  ?net_id:Net_id.t ->
  MBytes.t -> Operation.t list list ->
  (Block_hash.t * State.Block.t tzresult Lwt.t) tzresult Lwt.t

(** Monitor all the valid block (for all activate networks). *)
val watcher: t -> State.Block.t Lwt_stream.t * Lwt_watcher.stopper

val inject_operation:
  t ->
  ?net_id:Net_id.t ->
  Operation.t -> unit tzresult Lwt.t
