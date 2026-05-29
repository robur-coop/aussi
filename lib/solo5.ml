let src = Logs.Src.create "aussi.solo5.config"

module Log = (val Logs.src_log src)
module S = Map.Make (String)

let cidr =
  let dec = Ipaddr.Prefix.of_string_exn and enc = Ipaddr.Prefix.to_string in
  Jsont.map ~dec ~enc Jsont.string

let macaddr =
  let dec = Macaddr.of_string_exn and enc = Macaddr.to_string in
  Jsont.map ~dec ~enc Jsont.string

let fpath =
  let dec = Fpath.v and enc = Fpath.to_string in
  Jsont.map ~dec ~enc Jsont.string

module V1 = struct
  type t = {
      mem: int option
    ; argv: string list
          (* Templated unikernel argv; %{annotation.key} placeholders are
           resolved against the merged annotations by the runtime. *)
    ; nets: entry S.t
    ; blocks: block S.t
  }

  and entry =
    | Tap of {
          tap: string option (* host TAP interface name *)
        ; cidr: Ipaddr.Prefix.t option (* host-side address *)
        ; mac: Macaddr.t option (* guest MAC address *)
      }
    | Docker of {
          tap: string option (* host TAP interface name *)
        ; mac: Macaddr.t option (* guest MAC address *)
        ; iface: string
              (* netns interface to bridge with ("eth0", "eth1", ...) *)
      }

  and block = {
      path: Fpath.t (* host path of the file backing the device *)
    ; sector_size: int option (* in bytes; passed via --block-sector-size *)
  }

  let argv c = c.argv

  let entry =
    let open Jsont in
    let open Object in
    let tap_case =
      map (fun tap cidr mac -> (tap, cidr, mac))
      |> opt_mem "tap" Jsont.string ~enc:(fun (t, _, _) -> t)
      |> opt_mem "cidr" cidr ~enc:(fun (_, c, _) -> c)
      |> opt_mem "mac" macaddr ~enc:(fun (_, _, m) -> m)
      |> finish
    in
    let tap_case =
      Case.map "tap" tap_case ~dec:(fun (tap, cidr, mac) ->
          Tap { tap; cidr; mac })
    in
    let docker_case =
      map (fun tap mac iface -> (tap, mac, iface))
      |> opt_mem "tap" Jsont.string ~enc:(fun (t, _, _) -> t)
      |> opt_mem "mac" macaddr ~enc:(fun (_, m, _) -> m)
      |> mem "iface" Jsont.string ~enc:(fun (_, _, i) -> i)
      |> finish
    in
    let docker_case =
      Case.map "docker" docker_case ~dec:(fun (tap, mac, iface) ->
          Docker { tap; mac; iface })
    in
    let cases = Case.[ make tap_case; make docker_case ] in
    let enc_case = function
      | Tap { tap; cidr; mac } -> Case.value tap_case (tap, cidr, mac)
      | Docker { tap; mac; iface } -> Case.value docker_case (tap, mac, iface)
    in
    map Fun.id
    |> case_mem "type" Jsont.string ~enc:Fun.id ~enc_case ~dec_absent:"tap"
         cases
    |> finish

  let block =
    Jsont.Object.map (fun path sector_size -> { path; sector_size })
    |> Jsont.Object.mem "path" fpath ~enc:(fun b -> b.path)
    |> Jsont.Object.opt_mem "sector-size" Jsont.int ~enc:(fun b ->
        b.sector_size)
    |> Jsont.Object.finish

  let t =
    let open Jsont in
    Object.map (fun mem argv nets blocks -> { mem; argv; nets; blocks })
    |> Object.opt_mem "mem" Jsont.int ~enc:(fun c -> c.mem)
    |> Object.mem "argv"
         Jsont.(list string)
         ~enc:(fun c -> c.argv)
         ~dec_absent:[]
    |> Object.mem "nets"
         (Object.as_string_map entry)
         ~enc:(fun c -> c.nets)
         ~dec_absent:S.empty
    |> Object.mem "blocks"
         (Object.as_string_map block)
         ~enc:(fun c -> c.blocks)
         ~dec_absent:S.empty
    |> Object.finish

  let addf ~key pp value anns =
    match value with Some v -> (key, Fmt.str "%a" pp v) :: anns | None -> anns

  let ( $ ) prefix name = Fmt.str "%s.%s" prefix name

  let to_annotations cfg =
    let anns = addf ~key:"solo5.mem" Fmt.int cfg.mem [] in
    let fn name entry anns =
      let key = Fmt.str "solo5.net.%s" name in
      match entry with
      | Tap { tap; cidr; mac } ->
          anns
          |> addf ~key Fmt.string tap
          |> addf ~key:(key $ "ip") Ipaddr.Prefix.pp cidr
          |> addf ~key:(key $ "mac") Macaddr.pp mac
      | Docker { tap; mac; iface } ->
          anns
          |> addf ~key Fmt.string tap
          |> addf ~key:(key $ "mac") Macaddr.pp mac
          |> List.cons (key $ "docker", iface)
    in
    let anns = S.fold fn cfg.nets anns in
    let fn name (b : block) anns =
      let key = Fmt.str "solo5.block.%s" name in
      anns
      |> addf ~key Fpath.pp (Some b.path)
      |> addf ~key:(key $ "sector-size") Fmt.int b.sector_size
    in
    let anns = S.fold fn cfg.blocks anns in
    anns
end

type t = V1 of V1.t

let t =
  let open Jsont in
  let v1 = Object.Case.map 1 V1.t ~dec:(fun v1 -> V1 v1) in
  let cases = Object.Case.[ make v1 ] in
  let enc_case (V1 v) = Object.Case.value v1 v in
  Object.map (fun t _ -> t)
  |> Object.case_mem "version" int ~enc:Fun.id ~enc_case cases
  |> Object.mem "type" ~enc:(Fun.const "solo5.config")
       (const string "solo5.config")
  |> Object.finish

let of_string str = Jsont_bytesrw.decode_string t str

let load rootfs =
  let filepath = Fpath.(rootfs / "solo5.json") in
  let s = Fpath.to_string filepath in
  if Sys.file_exists s && Sys.is_regular_file s then begin
    let ic = open_in_bin s in
    let finally () = close_in ic in
    Fun.protect ~finally @@ fun () ->
    let len = in_channel_length ic in
    let buf = Bytes.create len in
    really_input ic buf 0 len;
    let str = Bytes.unsafe_to_string buf in
    of_string str |> Result.to_option
  end
  else None

let merge_annotations ~defaults ~overrides =
  let merged = Hashtbl.create 16 in
  List.iter (fun (k, v) -> Hashtbl.replace merged k v) defaults;
  List.iter (fun (k, v) -> Hashtbl.replace merged k v) overrides;
  Hashtbl.fold (fun k v acc -> (k, v) :: acc) merged []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)
