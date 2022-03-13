open Grpc_lwt
open Lwt.Syntax

let call_server ~host ~admin_macaroon address port req =
  let* addresses =
    Lwt_unix.getaddrinfo address (string_of_int port)
      [ Unix.(AI_FAMILY PF_INET) ]
  in
  let socket = Lwt_unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  let* () = Lwt_unix.connect socket (List.hd addresses).Unix.ai_addr in
  let error_handler = function
    | `Invalid_response_body_length _resp ->
        Printf.printf "invalid response body length\n%!"
    | `Exn _exn -> Printf.printf "exception!\n%!"
    | `Malformed_response s -> Printf.printf "malformed response: %s\n%!" s
    | `Protocol_error (code, s) ->
        Printf.printf "protocol error: %s, %s\n%!"
          (H2.Error_code.to_string code)
          s
  in
  let* connection =
    H2_lwt_unix.Client.TLS.create_connection_with_default ~error_handler socket
    (*H2_lwt_unix.Client.SSL.create_connection_with_default ~error_handler socket*)
  in

  (* code generation *)
  let enc = Pbrt.Encoder.create () in
  Lightning.Lightning_pb.encode_query_routes_request req enc;
  let service = "lnrpc.Lightning" in
  let rpc = "QueryRoutes" in
  Printf.printf "calling grpc %s %s\n%!" service rpc;
  let _hdrs = [ ("Grpc-Metadata-macaroon", admin_macaroon) ] in
  let _hdrs = [ ("grpc-metadata-macaroon", admin_macaroon) ] in
  let hdrs = [ ("macaroon", admin_macaroon) ] in
  let hdrs = ("content-type", "application/grpc") :: hdrs in
  let hdrs =
    let authority = Printf.sprintf "%s:%d" host port in
    (":authority", authority) :: hdrs
  in
  Client.call ~service ~rpc ~headers:(H2.Headers.of_list hdrs)
    ~do_request:
      (H2_lwt_unix.Client.TLS.request connection
         ~error_handler
           (*H2_lwt_unix.Client.SSL.request connection ~error_handler*))
    ~handler:
      (Client.Rpc.unary (Pbrt.Encoder.to_string enc) ~f:(fun decoder ->
           let+ decoder = decoder in
           match decoder with
           | None -> Lightning.Lightning_types.default_query_routes_response ()
           | Some decoder ->
               let decoder = Pbrt.Decoder.of_string decoder in
               Lightning.Lightning_pb.decode_query_routes_response decoder))
    ()

let () =
  let open Lwt.Syntax in
  let port = 10009 in
  let address = "localhost" in
  if Array.length Sys.argv < 4 then (
    Printf.printf
      "usage: %s <pubkey> <amount> <last_hop_pubkey_in_base64> <admin_macaroon>\n\
       %!"
      Sys.argv.(0);
    exit 1);
  let pub_key = Sys.argv.(1) in
  let amt = Sys.argv.(2) |> Int64.of_string in
  let last_hop_pubkey = Sys.argv.(3) |> Base64.decode_exn |> Bytes.of_string in
  let admin_macaroon = Sys.argv.(4) in
  let req =
    Lightning.Lightning_types.default_query_routes_request ~pub_key ~amt
      ~last_hop_pubkey ()
  in
  Lwt_main.run
    (let+ res = call_server ~host:address ~admin_macaroon address port req in
     match res with
     | Ok (res, _) ->
         let open Printf in
         let open Lightning.Lightning_types in
         printf "=== query routes response!\n";
         printf "success_prob: %f\n" res.success_prob;
         printf "routes: %d\n" (List.length res.routes);
         List.iter
           (fun route ->
             printf "=====\n";
             printf " . total_time_lock: %d\n"
               (Int32.to_int route.total_time_lock);
             printf " . total_fees: %s\n" (Int64.to_string route.total_fees);
             printf " . total_amt: %s\n" (Int64.to_string route.total_amt);
             printf " . total_fees_msat: %s\n"
               (Int64.to_string route.total_fees_msat);
             printf " . total_amt_msat: %s\n"
               (Int64.to_string route.total_amt_msat);
             printf " . hops: %d\n" (List.length route.hops);
             List.iter
               (fun (hop : hop) ->
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
                 printf ". . custom_records: <not shown>\n")
               route.hops)
           res.routes;
         printf "flush\n%!"
     | Error _ -> print_endline "an error occurred\n%!")
