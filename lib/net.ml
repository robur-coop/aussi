let src = Logs.Src.create "aussi.net" ~doc:"Aussi network setup"
let msgf fmt = Fmt.kstr (fun msg -> `Msg msg) fmt

module Log = (val Logs.src_log src)

type guest =
  | Tap of {
        name: string
      ; tap: string
      ; cidr: Ipaddr.Prefix.t option
      ; mac: Macaddr.t option
    }
  | Docker of {
        name: string
      ; tap: string
      ; mac: Macaddr.t option
      ; iface: string
    }

let name = function Tap { name; _ } | Docker { name; _ } -> name
let tap = function Tap { tap; _ } | Docker { tap; _ } -> tap

let run_cmd args =
  let cmd = Bos.Cmd.of_list args in
  Log.debug (fun m -> m "exec: %s" (Bos.Cmd.to_string cmd));
  let run = Bos.OS.Cmd.run_out ~err:Bos.OS.Cmd.err_run_out cmd in
  match Bos.OS.Cmd.out_string ~trim:true run with
  | Ok (_, (_, `Exited 0)) -> Ok ()
  | Ok (out, (_, `Exited n)) ->
      let suffix = if out = "" then "" else ": " ^ out in
      let msg =
        Fmt.str "%s exited with %d%s" (Bos.Cmd.to_string cmd) n suffix
      in
      Log.err (fun m -> m "%s" msg);
      Error (`Msg msg)
  | Ok (out, (_, `Signaled n)) ->
      let suffix = if out = "" then "" else ": " ^ out in
      let msg =
        Fmt.str "%s killed by signal %d%s" (Bos.Cmd.to_string cmd) n suffix
      in
      Log.err (fun m -> m "%s" msg);
      Error (`Msg msg)
  | Error (`Msg msg) ->
      Log.err (fun m -> m "%s" msg);
      Error (`Msg msg)

type platform = Linux | FreeBSD | Unknown

let detect_platform () =
  let cmd = Bos.Cmd.(v "uname" % "-s") in
  match Bos.OS.Cmd.(run_out cmd |> out_string) with
  | Ok ("Linux", _) -> Linux
  | Ok ("FreeBSD", _) -> FreeBSD
  | _ -> Unknown

let platform = lazy (detect_platform ())

let in_netns ?netns args =
  match netns with
  | None -> run_cmd args
  | Some path ->
      let net = Fmt.str "--net=%a" Fpath.pp path in
      run_cmd ("nsenter" :: net :: "--" :: args)

let tap_exists ?netns tap =
  match Lazy.force platform with
  | Linux ->
      begin match netns with
      | None ->
          let filepath = Fpath.v (Fmt.str "/sys/class/net/%s" tap) in
          let result = Bos.OS.Path.exists filepath in
          Result.value ~default:false result
      | Some _ ->
          let result = in_netns ?netns [ "ip"; "link"; "show"; tap ] in
          Result.is_ok result
      end
  | FreeBSD | Unknown ->
      let result = run_cmd [ "ifconfig"; tap ] in
      Result.is_ok result

let create_tap ?netns tap =
  if tap_exists ?netns tap then Ok ()
  else
    match Lazy.force platform with
    | Linux -> in_netns ?netns [ "ip"; "tuntap"; "add"; tap; "mode"; "tap" ]
    | FreeBSD | Unknown -> run_cmd [ "ifconfig"; tap; "create" ]

let configure_cidr ?netns tap cidr =
  Log.info (fun m -> m "configuring %s with %a" tap Ipaddr.Prefix.pp cidr);
  match Lazy.force platform with
  | Linux ->
      let _ = in_netns ?netns [ "ip"; "addr"; "flush"; "dev"; tap ] in
      in_netns ?netns
        [ "ip"; "addr"; "add"; Ipaddr.Prefix.to_string cidr; "dev"; tap ]
  | FreeBSD | Unknown ->
      run_cmd [ "ifconfig"; tap; "inet"; Ipaddr.Prefix.to_string cidr ]

let link_up ?netns tap =
  Log.info (fun m -> m "bringing up %s" tap);
  match Lazy.force platform with
  | Linux -> in_netns ?netns [ "ip"; "link"; "set"; "dev"; tap; "up" ]
  | FreeBSD | Unknown -> run_cmd [ "ifconfig"; tap; "up" ]

let destroy_tap ?netns tap =
  if tap_exists ?netns tap then begin
    Log.info (fun m -> m "destroying tap interface %s" tap);
    match Lazy.force platform with
    | Linux -> in_netns ?netns [ "ip"; "tuntap"; "del"; tap; "mode"; "tap" ]
    | FreeBSD | Unknown -> run_cmd [ "ifconfig"; tap; "destroy" ]
  end
  else Ok ()

let parse_interfaces annotations =
  let tbl = Hashtbl.create 8 in
  let get n =
    match Hashtbl.find_opt tbl n with
    | Some v -> v
    | None -> (None, None, None, None)
  in
  List.iter
    (fun (k, v) ->
      match String.split_on_char '.' k with
      | [ "solo5"; "net"; n ] ->
          let _, cidr, mac, iface = get n in
          Hashtbl.replace tbl n (Some v, cidr, mac, iface)
      | [ "solo5"; "net"; n; "cidr" ] -> (
          match Ipaddr.Prefix.of_string v with
          | Ok cidr ->
              let t, _, mac, iface = get n in
              Hashtbl.replace tbl n (t, Some cidr, mac, iface)
          | Error (`Msg msg) ->
              Log.warn (fun m ->
                  m "ignoring invalid annotation %s = %S: %s" k v msg))
      | [ "solo5"; "net"; n; "mac" ] -> (
          match Macaddr.of_string v with
          | Ok mac ->
              let t, cidr, _, iface = get n in
              Hashtbl.replace tbl n (t, cidr, Some mac, iface)
          | Error (`Msg msg) ->
              Log.warn (fun m ->
                  m "ignoring invalid annotation %s = %S: %s" k v msg))
      | [ "solo5"; "net"; n; "docker" ] ->
          let t, cidr, mac, _ = get n in
          Hashtbl.replace tbl n (t, cidr, mac, Some v)
      | _ -> ())
    annotations;
  Hashtbl.fold
    (fun n (t, cidr, mac, docker) acc ->
      let t = match t with Some t -> t | None -> "v" ^ n in
      let iface =
        match docker with
        | Some iface -> Docker { name= n; tap= t; mac; iface }
        | None -> Tap { name= n; tap= t; cidr; mac }
      in
      iface :: acc)
    tbl []
  |> List.sort (fun a b -> String.compare (name a) (name b))

let setup ?netns interfaces =
  let ( let* ) = Result.bind in
  let rec go = function
    | [] -> Ok ()
    | Docker _ :: rest -> go rest
    | (Tap { cidr; _ } as iface) :: rest ->
        let t = tap iface in
        let* () = create_tap ?netns t in
        let* () =
          match cidr with
          | Some cidr -> configure_cidr ?netns t cidr
          | None -> Ok ()
        in
        let* () = link_up ?netns t in
        go rest
  in
  go interfaces

let teardown ?netns interfaces =
  List.iter
    (fun iface ->
      let t = tap iface in
      match destroy_tap ?netns t with
      | Ok () -> ()
      | Error (`Msg msg) ->
          Log.warn (fun m -> m "failed to destroy %s: %s" t msg))
    interfaces

type host = {
    ifname: string (* "eth0", "eth1" *)
  ; cidr: Ipaddr.V4.Prefix.t option (* "172.17.0.2/16" *)
  ; cidr6: Ipaddr.V6.Prefix.t option (* "fd00::2/64" *)
  ; gateway: Ipaddr.V4.t option (* IPv4 default route *)
  ; mac: Macaddr.t (* "aa:bb:cc:dd:ee:ff" *)
}

(* JSON decoders for [ip -j addr show ...] and [ip -j route show default]. *)

let ipv4 =
  let enc = Ipaddr.V4.to_string in
  let dec = Ipaddr.V4.of_string_exn in
  Jsont.map ~dec ~enc Jsont.string

let ipv6 =
  let enc = Ipaddr.V6.to_string in
  let dec = Ipaddr.V6.of_string_exn in
  Jsont.map ~dec ~enc Jsont.string

let macaddr =
  let enc = Macaddr.to_string in
  let dec = Macaddr.of_string_exn in
  Jsont.map ~dec ~enc Jsont.string

let addr =
  let open Jsont in
  let open Object in
  let ipv4 =
    let fn local prefixlen = Ipaddr.V4.Prefix.make prefixlen local in
    map fn
    |> mem "local" ~enc:Ipaddr.V4.Prefix.address ipv4
    |> mem "prefixlen" ~enc:Ipaddr.V4.Prefix.bits int
    |> finish
  in
  let ipv4 = Case.map "inet" ipv4 ~dec:(fun ipv4 -> Ipaddr.V4 ipv4) in
  let ipv6 =
    let fn local prefixlen = Ipaddr.V6.Prefix.make prefixlen local in
    map fn
    |> mem "local" ~enc:Ipaddr.V6.Prefix.address ipv6
    |> mem "prefixlen" ~enc:Ipaddr.V6.Prefix.bits int
    |> finish
  in
  let ipv6 = Case.map "inet6" ipv6 ~dec:(fun ipv6 -> Ipaddr.V6 ipv6) in
  let cases = Case.[ make ipv4; make ipv6 ] in
  let enc_case = function
    | Ipaddr.V4 value -> Case.value ipv4 value
    | Ipaddr.V6 value -> Case.value ipv6 value
  in
  map Fun.id |> case_mem "family" string ~enc:Fun.id ~enc_case cases |> finish

let link =
  let open Jsont in
  Object.map (fun ifname address addr_info -> (ifname, address, addr_info))
  |> Object.mem "ifname" Jsont.string ~enc:(fun (n, _, _) -> n)
  |> Object.mem "address" macaddr ~enc:(fun (_, a, _) -> a)
  |> Object.mem "addr_info"
       Jsont.(list addr)
       ~enc:(fun (_, _, ai) -> ai)
       ~dec_absent:[]
  |> Object.finish

let route =
  let open Jsont in
  Object.map (fun gw dev -> (gw, dev))
  |> Object.opt_mem "gateway" ipv4 ~enc:(fun (gw, _) -> gw)
  |> Object.opt_mem "dev" Jsont.string ~enc:(fun (_, d) -> d)
  |> Object.finish

let nsenter_capture netns args =
  let cmd =
    let open Bos.Cmd in
    let net = Fmt.str "--net=%a" Fpath.pp netns in
    v "nsenter" % net % "--" %% of_list args
  in
  Log.debug (fun m -> m "exec: %s" (Bos.Cmd.to_string cmd));
  match Bos.OS.Cmd.(run_out cmd |> out_string ~trim:false) with
  | Ok (output, (_, `Exited 0)) -> Ok output
  | Ok (_, (_, `Exited n)) ->
      let msg = Fmt.str "%s exited with %d" (Bos.Cmd.to_string cmd) n in
      Log.err (fun m -> m "%s" msg);
      Error (`Msg msg)
  | Ok (_, (_, `Signaled n)) ->
      let msg = Fmt.str "%s killed by signal %d" (Bos.Cmd.to_string cmd) n in
      Log.err (fun m -> m "%s" msg);
      Error (`Msg msg)
  | Error (`Msg msg) ->
      Log.err (fun m -> m "%s" msg);
      Error (`Msg msg)

let of_json w str =
  Jsont_bytesrw.decode_string w str
  |> Result.map_error (fun _ -> msgf "Invalid JSON object")

let inspect_docker_ifaces netns =
  let ( let* ) = Result.bind in
  let* str = nsenter_capture netns [ "ip"; "-j"; "addr"; "show" ] in
  let* links = of_json Jsont.(list link) str in
  let* str = nsenter_capture netns [ "ip"; "-j"; "route"; "show"; "default" ] in
  let* routes = of_json Jsont.(list route) str in
  let gateway_for ifname =
    let fn = function
      | Some gw, Some dev when dev = ifname -> Some gw
      | _ -> None
    in
    List.find_map fn routes
  in
  let to_info (ifname, mac, addrs) =
    if ifname = "lo" then None
    else
      let fn = function Ipaddr.V4 v -> Some v | _ -> None in
      let cidr = List.find_map fn addrs in
      let fn = function Ipaddr.V6 v -> Some v | _ -> None in
      let cidr6 = List.find_map fn addrs in
      let gateway = gateway_for ifname in
      match (cidr, cidr6) with
      | None, None -> None
      | _ -> Some { ifname; cidr; cidr6; gateway; mac }
  in
  let ifaces =
    List.filter_map to_info links
    |> List.sort (fun a b -> String.compare a.ifname b.ifname)
  in
  Ok ifaces

let bridge_with_iface ~netns ~tap ~bridge ~src =
  let ( let* ) = Result.bind in
  Log.info (fun m ->
      m "Bridging tap %s with %s in netns %a via %s" tap src Fpath.pp netns
        bridge);
  let* () = create_tap ~netns tap in
  let* () = link_up ~netns tap in
  let* () =
    if tap_exists ~netns bridge then Ok ()
    else in_netns ~netns [ "ip"; "link"; "add"; bridge; "type"; "bridge" ]
  in
  let* () = in_netns ~netns [ "ip"; "link"; "set"; tap; "master"; bridge ] in
  let* () = in_netns ~netns [ "ip"; "link"; "set"; src; "master"; bridge ] in
  let* () = in_netns ~netns [ "ip"; "addr"; "flush"; "dev"; src ] in
  let* () = in_netns ~netns [ "ip"; "link"; "set"; bridge; "up" ] in
  Ok ()

let to_hvt_args interfaces =
  let render n t m =
    let net = [ "--net:" ^ n ^ "=" ^ t ] in
    let mac =
      match m with
      | Some m -> [ "--net-mac:" ^ n ^ "=" ^ Macaddr.to_string m ]
      | None -> []
    in
    net @ mac
  in
  List.concat_map
    (function
      | Tap { name; tap; mac; _ } -> render name tap mac
      | Docker { name; tap; mac; _ } -> render name tap mac)
    interfaces
