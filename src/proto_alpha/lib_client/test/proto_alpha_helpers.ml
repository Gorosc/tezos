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

let (//) = Filename.concat

let () = Random.self_init ()

let rpc_config = ref {
    Client_rpcs.host = "localhost" ;
    port = 8192 + Random.int 8192 ;
    tls = false ;
    logger = RPC_client.null_logger ;
  }

(* Context that does not write to alias files *)
let no_write_context config block : Client_commands.full_context = object
  inherit Client_rpcs.http_ctxt config
  inherit Client_commands.logger (fun _ _ -> Lwt.return_unit)
  method load : type a. string -> default:a -> a Data_encoding.encoding -> a Error_monad.tzresult Lwt.t =
    fun _ ~default _ -> return default
  method write : type a. string ->
    a ->
    a Data_encoding.encoding -> unit Error_monad.tzresult Lwt.t =
    fun _ _ _ -> return ()
  method block = block
end

let activate_alpha () =
  let fitness = Fitness_repr.from_int64 0L in
  let dictator_sk = Client_keys.Secret_key_locator.create
      ~scheme:"unencrypted"
      ~location:"edsk31vznjHSSpGExDMHYASz45VZqXN4DPxvsa4hAyY8dHM28cZzp6" in
  Tezos_client_genesis.Client_proto_main.bake
    (new Client_rpcs.http_ctxt !rpc_config) (`Head 0)
    (Activate  { protocol = Client_proto_main.protocol ;
                 fitness })
    dictator_sk

let init ?exe ?(sandbox = "sandbox.json") ?rpc_port () =
  begin
    match rpc_port with
    | None -> ()
    | Some port -> rpc_config := { !rpc_config with port }
  end ;
  let pid =
    Node_helpers.fork_node
      ?exe
      ~port:!rpc_config.port
      ~sandbox
      () in
  activate_alpha () >>=? fun hash ->
  return (pid, hash)

let level block =
  Client_proto_rpcs.Context.level (new Client_rpcs.http_ctxt !rpc_config) block

module Account = struct

  type t = {
    alias : string ;
    sk : secret_key ;
    pk : public_key ;
    pkh : public_key_hash ;
    contract : Contract.t ;
  }

  let encoding =
    let open Data_encoding in
    conv
      (fun { alias ; sk ; pk ; pkh ; contract } ->
         (alias, sk, pk, pkh, contract)
      )
      (fun (alias, sk, pk, pkh, contract) ->
         { alias ; sk ; pk ; pkh ; contract })
      (obj5
         (req "alias" string)
         (req "sk" Ed25519.Secret_key.encoding)
         (req "pk" Ed25519.Public_key.encoding)
         (req "pkh" Ed25519.Public_key_hash.encoding)
         (req "contract" Contract.encoding))

  let pp_account ppf account =
    let json = Data_encoding.Json.construct encoding account in
    Format.fprintf ppf "%s" (Data_encoding_ezjsonm.to_string json)

  let create ?keys alias =
    let sk, pk = match keys with
      | Some keys -> keys
      | None -> let _, pk, sk = Ed25519.generate_key () in sk, pk in
    let pkh = Ed25519.Public_key.hash pk in
    let contract = Contract.default_contract pkh in
    { alias ; contract ; pkh ; pk ; sk }

  type destination = {
    alias : string ;
    contract : Contract.t ;
    pk : public_key ;
    pkh : public_key_hash ;
  }

  let destination_encoding =
    let open Data_encoding in
    conv
      (fun { alias ; pk ; pkh ; contract } ->
         (alias, pk, pkh, contract))
      (fun (alias, pk, pkh, contract) ->
         { alias ; pk ; pkh ; contract })
      (obj4
         (req "alias" string)
         (req "pk" Ed25519.Public_key.encoding)
         (req "pkh" Ed25519.Public_key_hash.encoding)
         (req "contract" Contract.encoding))

  let pp_destination ppf destination =
    let json = Data_encoding.Json.construct destination_encoding destination in
    Format.fprintf ppf "%s" (Data_encoding_ezjsonm.to_string json)

  let create_destination ~alias ~contract ~pk =
    let pkh = Ed25519.Public_key.hash pk in
    { alias ; contract ; pk ; pkh }

  type bootstrap_accounts = { b1 : t ; b2 : t ; b3 : t ; b4 : t ;  b5 : t  ; }

  let bootstrap_accounts =
    let bootstrap1_sk =
      "edsk3gUfUPyBSfrS9CCgmCiQsTCHGkviBDusMxDJstFtojtc1zcpsh" in
    let bootstrap2_sk =
      "edsk39qAm1fiMjgmPkw1EgQYkMzkJezLNewd7PLNHTkr6w9XA2zdfo" in
    let bootstrap3_sk =
      "edsk4ArLQgBTLWG5FJmnGnT689VKoqhXwmDPBuGx3z4cvwU9MmrPZZ" in
    let bootstrap4_sk =
      "edsk2uqQB9AY4FvioK2YMdfmyMrer5R8mGFyuaLLFfSRo8EoyNdht3" in
    let bootstrap5_sk =
      "edsk4QLrcijEffxV31gGdN2HU7UpyJjA8drFoNcmnB28n89YjPNRFm" in
    let cpt = ref 0 in
    match List.map begin fun sk ->
        incr cpt ;
        let sk = Ed25519.Secret_key.of_b58check_exn sk in
        let alias = Printf.sprintf "bootstrap%d" !cpt in
        let pk = Ed25519.Secret_key.to_public_key sk in
        let pkh = Ed25519.Public_key.hash pk in
        { alias ; contract = Contract.default_contract pkh; pkh ; pk ; sk }
      end [ bootstrap1_sk; bootstrap2_sk; bootstrap3_sk;
            bootstrap4_sk; bootstrap5_sk; ]
    with
    | [ b1 ; b2 ; b3 ; b4 ; b5 ] -> { b1 ; b2 ; b3 ; b4 ; b5 }
    | _ -> assert false

  let transfer
      ?(block = `Prevalidation)
      ?(fee = Tez.fifty_cents)
      ~(account:t)
      ~destination
      ~amount () =
    let src_sk = Client_keys.Secret_key_locator.create
        ~scheme:"unencrypted"
        ~location:(Ed25519.Secret_key.to_b58check account.sk) in
    Client_proto_context.transfer (new Client_rpcs.http_ctxt !rpc_config)
      block
      ~source:account.contract
      ~src_pk:account.pk
      ~src_sk
      ~destination
      ~amount
      ~fee ()

  let originate
      ?(block = `Prevalidation)
      ?delegate
      ?(fee = Tez.fifty_cents)
      ~(src:t)
      ~manager_pkh
      ~balance
      () =
    let delegatable, delegate = match delegate with
      | None -> false, None
      | Some delegate -> true, Some delegate in
    let src_sk = Client_keys.Secret_key_locator.create
        ~scheme:"unencrypted"
        ~location:(Ed25519.Secret_key.to_b58check src.sk) in
    Client_proto_context.originate_account
      ~source:src.contract
      ~src_pk:src.pk
      ~src_sk
      ~manager_pkh
      ~balance
      ~delegatable
      ?delegate
      ~fee
      block
      (new Client_rpcs.http_ctxt !rpc_config)
      ()

  let set_delegate
      ?(block = `Prevalidation)
      ?(fee = Tez.fifty_cents)
      ~contract
      ~manager_sk
      ~src_pk
      delegate_opt =
    Client_proto_context.set_delegate
      (new Client_rpcs.http_ctxt !rpc_config)
      block
      ~fee
      contract
      ~src_pk
      ~manager_sk
      delegate_opt

  let balance ?(block = `Prevalidation) (account : t) =
    Client_proto_rpcs.Context.Contract.balance (new Client_rpcs.http_ctxt !rpc_config)
      block account.contract

  (* TODO: gather contract related functions in a Contract module? *)
  let delegate ?(block = `Prevalidation) (contract : Contract.t) =
    Client_proto_rpcs.Context.Contract.delegate (new Client_rpcs.http_ctxt !rpc_config)
      block contract

end

module Protocol = struct

  open Account

  let voting_period_kind ?(block = `Prevalidation) () =
    Client_proto_rpcs.Context.voting_period_kind (new Client_rpcs.http_ctxt !rpc_config) block

  let proposals ?(block = `Prevalidation) ~src:({ pk; sk } : Account.t) proposals =
    Client_node_rpcs.Blocks.info (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun block_info ->
    Client_proto_rpcs.Context.next_level (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun next_level ->
    Client_proto_rpcs.Helpers.Forge.Delegate.proposals (new Client_rpcs.http_ctxt !rpc_config) block
      ~branch:block_info.hash
      ~source:pk
      ~period:next_level.voting_period
      ~proposals
      () >>=? fun bytes ->
    let signed_bytes = Ed25519.Signature.append sk bytes in
    return (Tezos_base.Operation.of_bytes_exn signed_bytes)

  let ballot ?(block = `Prevalidation) ~src:({ pk; sk } : Account.t) ~proposal ballot =
    let rpc = new Client_rpcs.http_ctxt !rpc_config in
    Client_node_rpcs.Blocks.info rpc block >>=? fun block_info ->
    Client_proto_rpcs.Context.next_level rpc block >>=? fun next_level ->
    Client_proto_rpcs.Helpers.Forge.Delegate.ballot rpc block
      ~branch:block_info.hash
      ~source:pk
      ~period:next_level.voting_period
      ~proposal
      ~ballot
      () >>=? fun bytes ->
    let signed_bytes = Ed25519.Signature.append sk bytes in
    return (Tezos_base.Operation.of_bytes_exn signed_bytes)

end

module Assert = struct

  include Assert

  let equal_pkh ?msg pkh1 pkh2 =
    let msg = Assert.format_msg msg in
    let eq pkh1 pkh2 =
      match pkh1, pkh2 with
      | None, None -> true
      | Some pkh1, Some pkh2 ->
          Ed25519.Public_key_hash.equal pkh1 pkh2
      | _ -> false in
    let prn = function
      | None -> "none"
      | Some pkh -> Ed25519.Public_key_hash.to_hex pkh in
    Assert.equal ?msg ~prn ~eq pkh1 pkh2

  let equal_tez ?msg tz1 tz2 =
    let msg = Assert.format_msg msg in
    let eq tz1 tz2 = Int64.equal (Tez.to_mutez tz1) (Tez.to_mutez tz2) in
    let prn = Tez.to_string in
    Assert.equal ?msg ~prn ~eq tz1 tz2

  let balance_equal ?block ~msg account expected_balance =
    Account.balance ?block account >>=? fun actual_balance ->
    match Tez.of_mutez expected_balance with
    | None ->
        failwith "invalid tez constant"
    | Some expected_balance ->
        return (equal_tez ~msg expected_balance actual_balance)

  let delegate_equal ?block ~msg contract expected_delegate =
    Account.delegate ?block contract >>|? fun actual_delegate ->
    equal_pkh ~msg expected_delegate actual_delegate

  let ecoproto_error f = function
    | Environment.Ecoproto_error errors ->
        List.exists f errors
    | _ -> false

  let hash op = Tezos_base.Operation.hash op

  let contain_error ?(msg="") ~f = function
    | Ok _ -> Kaputt.Abbreviations.Assert.fail "Error _" "Ok _" msg
    | Error error when not (List.exists f error) ->
        let error_str = Format.asprintf "%a" Error_monad.pp_print_error error in
        Kaputt.Abbreviations.Assert.fail "" error_str msg
    | _ -> ()

  let failed_to_preapply ~msg ?op f =
    contain_error ~msg ~f:begin function
      | Client_baking_forge.Failed_to_preapply (op', err) ->
          begin
            match op with
            | None -> true
            | Some op ->
                let h = hash op and h' = hash op' in
                Operation_hash.equal h h'
          end && List.exists (ecoproto_error f) err
      | _ -> false
    end

  let generic_economic_error ~msg =
    contain_error ~msg ~f:(ecoproto_error (fun _ -> true))

  let unknown_contract ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Raw_context.Storage_error _ -> true
        | _ -> false)
    end

  let non_existing_contract ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract_storage.Non_existing_contract _ -> true
        | _ -> false)
    end

  let balance_too_low ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract.Balance_too_low _ -> true
        | _ -> false)
    end

  let non_spendable ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract_storage.Unspendable_contract _ -> true
        | _ -> false)
    end

  let inconsistent_pkh ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract_storage.Inconsistent_hash _ -> true
        | _ -> false)
    end

  let inconsistent_public_key ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract_storage.Inconsistent_public_key _ -> true
        | _ -> false)
    end

  let missing_public_key ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract_storage.Missing_public_key _ -> true
        | _ -> false)
    end

  let initial_amount_too_low ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract.Initial_amount_too_low _ -> true
        | _ -> false)
    end

  let non_delegatable ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Contract_storage.Non_delegatable_contract _ -> true
        | _ -> false)
    end

  let wrong_delegate ~msg =
    contain_error ~msg ~f:begin ecoproto_error (function
        | Baking.Wrong_delegate _ -> true
        | _ -> false)
    end

  let check_protocol ?msg ~block h =
    Client_node_rpcs.Blocks.protocol (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun block_proto ->
    return @@ Assert.equal
      ?msg:(Assert.format_msg msg)
      ~prn:Protocol_hash.to_b58check
      ~eq:Protocol_hash.equal
      block_proto h

  let check_voting_period_kind ?msg ~block kind =
    Client_proto_rpcs.Context.voting_period_kind (new Client_rpcs.http_ctxt !rpc_config) block
    >>=? fun current_kind ->
    return @@ Assert.equal
      ?msg:(Assert.format_msg msg)
      current_kind kind

end

module Baking = struct

  let bake block (contract: Account.t) operations =
    let seed_nonce =
      match Nonce.of_bytes @@
        Sodium.Random.Bigbytes.generate Constants.nonce_length with
      | Error _ -> assert false
      | Ok nonce -> nonce in
    let seed_nonce_hash = Nonce.hash seed_nonce in
    let src_sk = Client_keys.Secret_key_locator.create
        ~scheme:"unencrypted"
        ~location:(Ed25519.Secret_key.to_b58check contract.sk) in
    Client_baking_forge.forge_block
      (new Client_rpcs.http_ctxt !rpc_config)
      block
      ~operations
      ~force:true
      ~best_effort:false
      ~sort:false
      ~priority:(`Auto (contract.pkh, Some 1024, false))
      ~seed_nonce_hash
      ~src_sk
      ()

  let endorsement_reward block =
    Client_proto_rpcs.Header.priority (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun prio ->
    Baking.endorsement_reward ~block_priority:prio >|=
    Environment.wrap_error >>|?
    Tez.to_mutez

end

module Endorse = struct

  let forge_endorsement
      block
      src_sk
      source
      slot =
    let block = Client_rpcs.last_baked_block block in
    let rpc = new Client_rpcs.http_ctxt !rpc_config in
    Client_node_rpcs.Blocks.info rpc block >>=? fun { hash ; _ } ->
    Client_proto_rpcs.Helpers.Forge.Delegate.endorsement rpc
      block
      ~branch:hash
      ~source
      ~block:hash
      ~slot:slot
      () >>=? fun bytes ->
    let signed_bytes = Ed25519.Signature.append src_sk bytes in
    return (Tezos_base.Operation.of_bytes_exn signed_bytes)

  let signing_slots
      ?(max_priority = 1024)
      block
      delegate
      level =
    Client_proto_rpcs.Helpers.Rights.endorsement_rights_for_delegate
      (new Client_rpcs.http_ctxt !rpc_config) ~max_priority ~first_level:level ~last_level:level
      block delegate () >>=? fun possibilities ->
    let slots =
      List.map (fun (_,slot) -> slot)
      @@ List.filter (fun (l, _) -> l = level) possibilities in
    return slots

  let endorse
      ?slot
      (contract : Account.t)
      block =
    Client_proto_rpcs.Context.next_level (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun { level } ->
    begin
      match slot with
      | Some slot -> return slot
      | None -> begin
          signing_slots
            block contract.Account.pkh
            level >>=? function
          | slot::_ -> return slot
          | [] ->
              failwith "No slot found at level %a" Raw_level.pp level
        end
    end >>=? fun slot ->
    forge_endorsement block contract.sk contract.pk slot

  (* FIXME @vb: I don't understand this function, copied from @cago. *)
  let endorsers_list block =
    let get_endorser_list result (account : Account.t) level block =
      Client_proto_rpcs.Helpers.Rights.endorsement_rights_for_delegate
        (new Client_rpcs.http_ctxt !rpc_config) block account.pkh
        ~max_priority:16
        ~first_level:level
        ~last_level:level () >>|? fun slots ->
      List.iter (fun (_,slot) -> result.(slot) <- account) slots
    in
    let { Account.b1 ; b2 ; b3 ; b4 ; b5 } = Account.bootstrap_accounts in
    let result = Array.make 16 b1 in
    Client_proto_rpcs.Context.level (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun level ->
    let level = Raw_level.succ @@ level.level in
    get_endorser_list result b1 level block >>=? fun () ->
    get_endorser_list result b2 level block >>=? fun () ->
    get_endorser_list result b3 level block >>=? fun () ->
    get_endorser_list result b4 level block >>=? fun () ->
    get_endorser_list result b5 level block >>=? fun () ->
    return result

  let endorsement_rights
      ?(max_priority = 1024)
      (contract : Account.t) block =
    let rpc = new Client_rpcs.http_ctxt !rpc_config in
    Client_proto_rpcs.Context.level rpc block >>=? fun level ->
    let delegate = contract.pkh in
    let level = level.level in
    Client_proto_rpcs.Helpers.Rights.endorsement_rights_for_delegate
      rpc
      ~max_priority
      ~first_level:level
      ~last_level:level
      block delegate ()

end

let display_level block =
  Client_proto_rpcs.Context.level (new Client_rpcs.http_ctxt !rpc_config) block >>=? fun lvl ->
  Format.eprintf "Level: %a@." Level.pp_full lvl ;
  return ()
