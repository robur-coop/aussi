let src = Logs.Src.create "aussi.manifest" ~doc:"Solo5 manifest"
let bpf buffer fmt = Printf.bprintf buffer fmt
let error_msgf fmt = Fmt.kstr (fun msg -> Error (`Msg msg)) fmt

module Log = (val Logs.src_log src)

type device_type = Net_basic | Block_basic
type device = { name: string; typ: device_type }
type t = { version: int; devices: device list }

let solo5_elftool =
  match Sys.getenv_opt "SOLO5_ELFTOOL" with
  | Some p -> p
  | None ->
      begin try
        let self = Unix.readlink "/proc/self/exe" in
        let candidate =
          Filename.concat (Filename.dirname self) "solo5-elftool"
        in
        if Sys.file_exists candidate then candidate else "solo5-elftool"
      with _ -> "solo5-elftool"
      end

let device_type =
  Jsont.enum [ ("NET_BASIC", Net_basic); ("BLOCK_BASIC", Block_basic) ]

let device =
  Jsont.Object.map ~kind:"device" (fun name typ -> { name; typ })
  |> Jsont.Object.mem "name" Jsont.string ~enc:(fun d -> d.name)
  |> Jsont.Object.mem "type" device_type ~enc:(fun d -> d.typ)
  |> Jsont.Object.finish

let t =
  Jsont.Object.map ~kind:"manifest" (fun _typ version devices ->
      { version; devices })
  |> Jsont.Object.mem "type" Jsont.string ~enc:(fun _ -> "solo5.manifest")
  |> Jsont.Object.mem "version" Jsont.int ~enc:(fun m -> m.version)
  |> Jsont.Object.mem "devices" Jsont.(list device) ~enc:(fun m -> m.devices)
  |> Jsont.Object.finish

(* Run solo5-elftool query-manifest on a .hvt binary *)
let query filepath =
  Log.info (fun m -> m "Querying manifest from %a" Fpath.pp filepath);
  let cmd =
    Bos.Cmd.(v solo5_elftool % "query-manifest" % Fpath.to_string filepath)
  in
  match Bos.OS.Cmd.(run_out ~err:err_null cmd |> out_string ~trim:false) with
  | Ok (json, (_, `Exited 0)) -> (
      match Jsont_bytesrw.decode_string t json with
      | Ok manifest -> Ok manifest
      | Error msg -> error_msgf "Failed to parse manifest: %s" msg)
  | Ok (_, (_, `Exited n)) -> error_msgf "solo5-elftool exited with %d" n
  | Ok (_, (_, `Signaled n)) -> error_msgf "solo5-elftool killed by signal %d" n
  | Error (`Msg msg) -> error_msgf "solo5-elftool: %s" msg

let device_type_to_string = function
  | Net_basic -> "NET_BASIC"
  | Block_basic -> "BLOCK_BASIC"

(* Validate that annotations provide all required devices. *)
let validate manifest annotations =
  let nets = Net.parse_interfaces annotations in
  let net_names = List.map Net.name nets in
  let block_names =
    List.filter_map
      (fun (k, _v) ->
        match String.split_on_char '.' k with
        | [ "solo5"; "block"; name ] -> Some name
        | _ -> None)
      annotations
  in
  let missing = ref [] in
  let unexpected = ref [] in
  (* Check every device in manifest has a matching annotation *)
  List.iter
    (fun (dev : device) ->
      match dev.typ with
      | Net_basic ->
          if not (List.mem dev.name net_names) then
            missing := (dev.name, dev.typ) :: !missing
      | Block_basic ->
          if not (List.mem dev.name block_names) then
            missing := (dev.name, dev.typ) :: !missing)
    manifest.devices;
  (* Check for annotations that don't match any device in the manifest *)
  let manifest_net_names =
    List.filter_map
      (fun (d : device) ->
        match d.typ with Net_basic -> Some d.name | _ -> None)
      manifest.devices
  in
  let manifest_block_names =
    List.filter_map
      (fun (d : device) ->
        match d.typ with Block_basic -> Some d.name | _ -> None)
      manifest.devices
  in
  List.iter
    (fun name ->
      if not (List.mem name manifest_net_names) then
        unexpected := (name, Net_basic) :: !unexpected)
    net_names;
  List.iter
    (fun name ->
      if not (List.mem name manifest_block_names) then
        unexpected := (name, Block_basic) :: !unexpected)
    block_names;
  match (!missing, !unexpected) with
  | [], [] -> Ok ()
  | missing, unexpected ->
      let buf = Buffer.create 256 in
      if missing <> [] then begin
        bpf buf
          "The unikernel requires the following devices that are not configured:\n";
        List.iter
          (fun (name, typ) ->
            bpf buf "  - %s (%s)\n" name (device_type_to_string typ))
          missing;
        bpf buf
          "add the appropriate solo5.net.<name> or solo5.block.<name> \
           annotations\n"
      end;
      if unexpected <> [] then begin
        bpf buf
          "The following configured devices are not declared in the unikernel \
           manifest:\n";
        List.iter
          (fun (name, typ) ->
            bpf buf "  - %s (%s)\n" name (device_type_to_string typ))
          unexpected;
        bpf buf "remove these annotations or check the device names\n"
      end;
      error_msgf "%s" (Buffer.contents buf)

let pp_devices ppf manifest =
  List.iter
    (fun (dev : device) ->
      Fmt.pf ppf "  %s (%s)@." dev.name (device_type_to_string dev.typ))
    manifest.devices
