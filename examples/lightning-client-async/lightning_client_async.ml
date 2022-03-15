open! Core
open! Async

let call_server ~host ~admin_macaroon address port req =
  let%bind addresses =
    Unix.Addr_info.get ~host:address ~service:(Int.to_string port)
      [ Unix.Addr_info.AI_FAMILY Unix.PF_INET ]
  in
  let%bind socket =
    let socket = Unix.Socket.create Unix.Socket.Type.tcp in
    let address =
      let sockaddr =
        match addresses with
        | hd :: _ -> hd.Unix.Addr_info.ai_addr
        | [] -> failwithf "call_server: no address for %s %d" host port ()
      in
      match sockaddr with
      | Unix.ADDR_INET (a, i) -> `Inet (a, i)
      | ADDR_UNIX u ->
          failwithf "can't make an Socket.Address.Inet out of a UNIX socket %s"
            u ()
    in
    Unix.Socket.connect socket address
  in
  let error_handler = function
    | `Invalid_response_body_length _resp ->
        printf "invalid response body length\n%!"
    | `Exn _exn -> printf "exception!\n%!"
    | `Malformed_response s -> printf "malformed response: %s\n%!" s
    | `Protocol_error (code, s) ->
        printf "protocol error: %s, %s\n%!" (H2.Error_code.to_string code) s
  in
  let%bind connection =
    (* XXX: instead of verify_none, we should load the client-side CA from the lnd dir, like rebalance-lnd does. *)
    H2_async.Client.SSL.create_connection_with_default
      ~verify_modes:[ `Verify_none ]
      ~error_handler socket
  in
  (* code generation *)
  let enc = Pbrt.Encoder.create () in
  Lightning.Lightning_pb.encode_query_routes_request req enc;
  let service = "lnrpc.Lightning" in
  let rpc = "QueryRoutes" in
  printf "calling grpc %s %s\n%!" service rpc;
  let _hdrs = [ ("Grpc-Metadata-macaroon", admin_macaroon) ] in
  let _hdrs = [ ("grpc-metadata-macaroon", admin_macaroon) ] in
  let hdrs = [ ("macaroon", admin_macaroon) ] in
  let hdrs = ("content-type", "application/grpc") :: hdrs in
  let hdrs =
    let authority = Printf.sprintf "%s:%d" host port in
    (":authority", authority) :: hdrs
  in
  Grpc_async.Client.call ~service ~rpc ~headers:(H2.Headers.of_list hdrs)
    ~do_request:(H2_async.Client.SSL.request connection ~error_handler)
    ~handler:
      (Grpc_async.Client.Rpc.unary (Pbrt.Encoder.to_string enc)
         ~f:(fun decoder ->
           match%map decoder with
           | `Eof -> Lightning.Lightning_types.default_query_routes_response ()
           | `Ok decoder ->
               let decoder = Pbrt.Decoder.of_string decoder in
               Lightning.Lightning_pb.decode_query_routes_response decoder))
    ()

let () =
  let argv = Sys.get_argv () in
  let port = 10009 in
  let address = "localhost" in
  match argv with
  | [| _arg0; pub_key; amt; last_hop_pubkey; admin_macaroon |] ->
      let last_hop_pubkey =
        last_hop_pubkey |> Base64.decode_exn |> Bytes.of_string
      in
      let req =
        Lightning.Lightning_types.default_query_routes_request ~pub_key
          ~amt:(amt |> Int.of_string |> Int64.of_int)
          ~last_hop_pubkey ()
      in
      don't_wait_for
        (match%map
           call_server ~host:address ~admin_macaroon address port req
         with
        | Error _ -> print_endline "an error occurred\n%!"
        | Ok (res, _) ->
            let open Lightning.Lightning_types in
            printf "=== query routes response!\n";
            printf "success_prob: %f\n" res.success_prob;
            printf "routes: %d\n" (List.length res.routes);
            List.iter res.routes ~f:(fun route ->
                printf "=====\n";
                printf " . total_time_lock: %d\n"
                  (Int32.to_int_exn route.total_time_lock);
                printf " . total_fees: %s\n" (Int64.to_string route.total_fees);
                printf " . total_amt: %s\n" (Int64.to_string route.total_amt);
                printf " . total_fees_msat: %s\n"
                  (Int64.to_string route.total_fees_msat);
                printf " . total_amt_msat: %s\n"
                  (Int64.to_string route.total_amt_msat);
                printf " . hops: %d\n" (List.length route.hops);
                List.iter route.hops ~f:(fun (hop : hop) ->
                    printf "--------\n";
                    printf ". . chan_id: %s\n" (Int64.to_string hop.chan_id);
                    printf ". . chan_capacity: %s\n"
                      (Int64.to_string hop.chan_capacity);
                    printf ". . amt_to_forward: %s\n"
                      (Int64.to_string hop.amt_to_forward);
                    printf ". . fee: %s\n" (Int64.to_string hop.fee);
                    printf ". . expiry: %s\n" (Int32.to_string hop.expiry);
                    printf ". . amt_to_forward_msat: %s\n"
                      (Int64.to_string hop.amt_to_forward_msat);
                    printf ". . fee_msat: %s\n" (Int64.to_string hop.fee_msat);
                    printf ". . pub_key: %s\n" hop.pub_key;
                    printf ". . tlv_payload: %B\n" hop.tlv_payload;
                    printf ". . mpp_record: <not shown>\n";
                    printf ". . amp_record: <not shown>\n";
                    printf ". . custom_records: <not shown>\n")));
      never_returns (Scheduler.go ())
  | _ ->
      Stdlib.Printf.printf
        "usage: <pub_key> <amount> <last_hop_pubkey> <admin macaroon>\n%!"
