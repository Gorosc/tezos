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

module ContractEntity = struct
  type t = Contract.t
  let encoding = Contract.encoding
  let of_source s =
    match Contract.of_b58check s with
    | Error _ as err ->
        Lwt.return (Environment.wrap_error err)
        |> trace (failure "bad contract notation")
    | Ok s -> return s
  let to_source s = return (Contract.to_b58check s)
  let name = "contract"
end

module RawContractAlias = Client_aliases.Alias (ContractEntity)

module ContractAlias = struct

  let find cctxt s =
    RawContractAlias.find_opt cctxt s >>=? function
    | Some v -> return (s, v)
    | None ->
        Client_keys.Public_key_hash.find_opt cctxt s >>=? function
        | Some v ->
            return (s, Contract.default_contract v)
        | None ->
            failwith "no contract or key named %s" s

  let find_key cctxt name =
    Client_keys.Public_key_hash.find cctxt name >>=? fun v ->
    return (name, Contract.default_contract v)

  let rev_find cctxt c =
    match Contract.is_default c with
    | Some hash -> begin
        Client_keys.Public_key_hash.rev_find cctxt hash >>=? function
        | Some name -> return (Some ("key:" ^ name))
        | None -> return None
      end
    | None -> RawContractAlias.rev_find cctxt c

  let get_contract cctxt s =
    match String.split ~limit:1 ':' s with
    | [ "key" ; key ]->
        find_key cctxt key
    | _ -> find cctxt s

  let autocomplete cctxt =
    Client_keys.Public_key_hash.autocomplete cctxt >>=? fun keys ->
    RawContractAlias.autocomplete cctxt >>=? fun contracts ->
    return (List.map ((^) "key:") keys @ contracts)

  let alias_param ?(name = "name") ?(desc = "existing contract alias") next =
    let desc =
      desc ^ "\n"
      ^ "Can be a contract alias or a key alias (autodetected in order).\n\
         Use 'key:name' to force the later." in
    Cli_entries.(
      param ~name ~desc
        (parameter ~autocomplete:autocomplete
           (fun cctxt p -> get_contract cctxt p))
        next)

  let destination_param ?(name = "dst") ?(desc = "destination contract") next =
    let desc =
      desc ^ "\n"
      ^ "Can be an alias, a key, or a literal (autodetected in order).\n\
         Use 'text:literal', 'alias:name', 'key:name' to force." in
    Cli_entries.(
      param ~name ~desc
        (parameter
           ~autocomplete:(fun cctxt ->
               autocomplete cctxt >>=? fun list1 ->
               Client_keys.Public_key_hash.autocomplete cctxt >>=? fun list2 ->
               return (list1 @ list2))
           (fun cctxt s ->
              begin
                match String.split ~limit:1 ':' s with
                | [ "alias" ; alias ]->
                    find cctxt alias
                | [ "key" ; text ] ->
                    Client_keys.Public_key_hash.find cctxt text >>=? fun v ->
                    return (s, Contract.default_contract v)
                | _ ->
                    find cctxt s >>= function
                    | Ok v -> return v
                    | Error k_errs ->
                        ContractEntity.of_source s >>= function
                        | Ok v -> return (s, v)
                        | Error c_errs ->
                            Lwt.return (Error (k_errs @ c_errs))
              end)))
      next

  let name cctxt contract =
    rev_find cctxt contract >>=? function
    | None -> return (Contract.to_b58check contract)
    | Some name -> return name

end

module Contract_tags = Client_tags.Tags (struct
    let name = "contract"
  end)

let list_contracts cctxt =
  RawContractAlias.load cctxt >>=? fun raw_contracts ->
  Lwt_list.map_s
    (fun (n, v) -> Lwt.return ("", n, v))
    raw_contracts >>= fun contracts ->
  Client_keys.Public_key_hash.load cctxt >>=? fun keys ->
  (* List accounts (default contracts of identities) *)
  map_s (fun (n, v) ->
      RawContractAlias.mem cctxt n >>=? fun mem ->
      let p = if mem then "key:" else "" in
      let v' = Contract.default_contract v in
      return (p, n, v'))
    keys >>=? fun accounts ->
  return (contracts @ accounts)

let get_manager cctxt block source =
  match Contract.is_default source with
  | Some hash -> return hash
  | None -> Client_proto_rpcs.Context.Contract.manager cctxt block source

let get_delegate cctxt block source =
  match Contract.is_default source with
  | Some hash -> return hash
  | None ->
      Client_proto_rpcs.Context.Contract.delegate cctxt
        block source >>=? function
      | Some delegate ->
          return delegate
      | None ->
          Client_proto_rpcs.Context.Contract.manager cctxt block source

let may_check_key sourcePubKey sourcePubKeyHash =
  match sourcePubKey with
  | Some sourcePubKey ->
      fail_unless
        (Ed25519.Public_key_hash.equal
           (Ed25519.Public_key.hash sourcePubKey) sourcePubKeyHash)
        (failure "Invalid public key in `client_proto_endorsement`")
  | None ->
      return ()

let check_public_key cctxt block ?src_pk src_pk_hash =
  Client_proto_rpcs.Context.Key.get cctxt block src_pk_hash >>= function
  | Error errors ->
      begin
        match src_pk with
        | None ->
            let exn = Client_proto_rpcs.string_of_errors errors in
            failwith "Unknown public key\n%s" exn
        | Some key ->
            may_check_key src_pk src_pk_hash >>=? fun () ->
            return (Some key)
      end
  | Ok _ -> return None
