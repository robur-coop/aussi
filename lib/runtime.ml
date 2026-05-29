let src = Logs.Src.create "aussi.runtime"
let error_msgf fmt = Fmt.kstr (fun msg -> Error (`Msg msg)) fmt
let inhibit fn = try fn () with _exn -> ()
let ( let* ) = Result.bind

module Log = (val Logs.src_log src)

module Global : sig
  val get_root : unit -> Fpath.t
  val set_root : Fpath.t -> unit
  val solo5_hvt : string (* executable *)
end = struct
  let root = ref (Fpath.v "/run/aussi/")
  let get_root () = !root
  let set_root path = root := path

  let solo5_hvt =
    match Sys.getenv_opt "SOLO5_HVT" with Some p -> p | None -> "solo5-hvt"
end

let state_dir id = Fpath.(Global.get_root () / id)
let state_file id = Fpath.(state_dir id / "state.json")
let internal_pid_file id = Fpath.(state_dir id / "pid")
let config_file id = Fpath.(state_dir id / "config.json")
let net_file id = Fpath.(state_dir id / "net.json")
let exit_code_file id = Fpath.(state_dir id / "exit_code")
let placeholder_pid_file id = Fpath.(state_dir id / "placeholder_pid")
let exec_fifo id = Fpath.(state_dir id / "exec.fifo")
let exec_argv_file id = Fpath.(state_dir id / "exec.argv")

let load_state id =
  match Bos.OS.File.read (state_file id) with
  | Error _ -> None
  | Ok content -> State.of_string content |> Result.to_option

let save_state (state : State.t) =
  let* _ = Bos.OS.Dir.create (Global.get_root ()) in
  let* _ = Bos.OS.Dir.create (state_dir state.id) in
  let* json = State.to_string state in
  Bos.OS.File.write (state_file state.id) json

let cidr =
  let enc = Ipaddr.Prefix.to_string and dec = Ipaddr.Prefix.of_string_exn in
  Jsont.map ~enc ~dec Jsont.string

let macaddr =
  let enc = Macaddr.to_string and dec = Macaddr.of_string_exn in
  Jsont.map ~enc ~dec Jsont.string

let iface =
  let open Jsont in
  let open Object in
  let docker =
    let fn name tap mac iface = (name, tap, mac, iface) in
    map fn
    |> mem "name" ~enc:(fun (name, _, _, _) -> name) string
    |> mem "tap" ~enc:(fun (_, tap, _, _) -> tap) string
    |> opt_mem "mac" ~enc:(fun (_, _, mac, _) -> mac) macaddr
    |> mem "iface" ~enc:(fun (_, _, _, iface) -> iface) string
    |> finish
  in
  let docker =
    Case.map "docker" docker ~dec:(fun (name, tap, mac, iface) ->
        Net.Docker { name; tap; mac; iface })
  in
  let tap =
    let fn name tap mac cidr = (name, tap, mac, cidr) in
    map fn
    |> mem "name" ~enc:(fun (name, _, _, _) -> name) string
    |> mem "tap" ~enc:(fun (_, tap, _, _) -> tap) string
    |> opt_mem "mac" ~enc:(fun (_, _, mac, _) -> mac) macaddr
    |> opt_mem "cidr" ~enc:(fun (_, _, _, cidr) -> cidr) cidr
    |> finish
  in
  let tap =
    Case.map "tap" tap ~dec:(fun (name, tap, mac, cidr) ->
        Net.Tap { name; tap; cidr; mac })
  in
  let cases = Case.[ make docker; make tap ] in
  let enc_case = function
    | Net.Docker { name; tap; mac; iface } ->
        Case.value docker (name, tap, mac, iface)
    | Net.Tap { name; tap= tapname; mac; cidr } ->
        Case.value tap (name, tapname, mac, cidr)
  in
  map Fun.id |> case_mem "type" string ~enc:Fun.id ~enc_case cases |> finish

let ifaces = Jsont.list iface

let save_net id interfaces =
  let format = Jsont.Indent in
  match Jsont_bytesrw.encode_string ~format ifaces interfaces with
  | Ok json -> ignore (Bos.OS.File.write (net_file id) json)
  | Error _ -> ()

let load_net id =
  match Bos.OS.File.read (net_file id) with
  | Error _ -> []
  | Ok content ->
      let result = Jsont_bytesrw.decode_string ifaces content in
      Result.value ~default:[] result

let find_unikernel rootfs args =
  let with_rootfs exe =
    let exe =
      if String.length exe > 0 && exe.[0] = '/' then
        String.sub exe 1 (String.length exe - 1)
      else exe
    in
    match Fpath.of_string exe with
    | Ok rel -> Some Fpath.(rootfs // rel)
    | Error _ -> None
  in
  let is_regular path =
    Bos.OS.File.exists path |> Result.value ~default:false
  in
  let auto_detect () =
    let* entries = Bos.OS.Dir.contents rootfs in
    let fn path = is_regular path && Fpath.has_ext ".hvt" path in
    match List.filter fn entries with
    | [ filepath ] -> Ok filepath
    | [] -> error_msgf "No .hvt unikernel found in rootfs"
    | _ ->
        error_msgf "Multiple .hvt files in rootfs, specify one in process.args"
  in
  match args with
  | exe :: _ ->
      begin match with_rootfs exe with
      | Some p when is_regular p -> Ok p
      | _ -> auto_detect ()
      end
  | [] -> auto_detect ()

(* Substitution *)
let subst_annotations annotations s =
  let n = String.length s in
  let buf = Buffer.create n in
  let i = ref 0 in
  while !i < n do
    if !i + 1 < n && s.[!i] = '%' && s.[!i + 1] = '{' then
      begin match String.index_from_opt s (!i + 2) '}' with
      | Some j ->
          let key = String.sub s (!i + 2) (j - (!i + 2)) in
          Buffer.add_string buf
            (Option.value ~default:"" (List.assoc_opt key annotations));
          i := j + 1
      | None ->
          Buffer.add_char buf s.[!i];
          incr i
      end
    else begin
      Buffer.add_char buf s.[!i];
      incr i
    end
  done;
  Buffer.contents buf

(* From annotations to argv (with substitution). *)
let resolve_unikernel_argv rootfs annotations =
  let template =
    match List.assoc_opt "solo5.cmdline" annotations with
    | Some s -> List.filter (fun x -> x <> "") (String.split_on_char ' ' s)
    | None ->
        let cfg = Solo5.load rootfs in
        let argv = Option.map (fun (Solo5.V1 cfg) -> Solo5.V1.argv cfg) cfg in
        Option.value ~default:[] argv
  in
  List.map (subst_annotations annotations) template

let build_hvt_args ?(extra_argv = []) annotations interfaces unikernel_path
    process_args =
  let mem =
    match List.assoc_opt "solo5.mem" annotations with
    | Some m -> [ "--mem=" ^ m ]
    | None -> []
  in
  let net_args = Net.to_hvt_args interfaces in
  let block_args =
    List.filter_map
      (fun (k, v) ->
        match String.split_on_char '.' k with
        | [ "solo5"; "block"; name ] -> Some ("--block:" ^ name ^ "=" ^ v)
        | [ "solo5"; "block"; name; "sector-size" ] ->
            Some ("--block-sector-size:" ^ name ^ "=" ^ v)
        | _ -> None)
      annotations
  in
  let unikernel_args = match process_args with _ :: rest -> rest | [] -> [] in
  mem @ net_args @ block_args
  @ [ "--"; Fpath.to_string unikernel_path ]
  @ extra_argv @ unikernel_args

let process_is_alive pid =
  try Unix.kill pid 0; true with Unix.Unix_error _ -> false

let collect_exit_status pid =
  try
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ -> None
    | _, Unix.WEXITED n -> Some n
    | _, Unix.WSIGNALED n -> Some (128 + n)
    | _, Unix.WSTOPPED _ -> None
  with Unix.Unix_error _ -> None

let spawn_placeholder ~own_netns ~state_dir =
  let pid_rd, pid_wr = Unix.pipe ~cloexec:true () in
  let self =
    try Unix.readlink "/proc/self/exe" with _ -> Sys.executable_name
  in
  (* NOTE(dinosaure): here, the goal is to create an "orphan" process which can
     live between [aussi create] and [aussi start]. We do a "double-fork":
     + we do a [fork(2)] and name the child [intermediate]
       * the initial [aussi] process waits to read the PID of the process that
         is about to launch [solo5-hvt]
       + the [intermediate] (the child) process redo a [fork(2)]
         * and exit itself, this means that the child-child in question will
           become an "orphan"
         + the new child-child writes its PID to the initial process (via our 
           initial [Unix.pipe] [pid_wr])
    
     [containerd-shim] (which is the parent of our initial [aussi] process) has
     been configured to catch our orphaned process (when an orphaned process
     exists (see [PR_SET_CHILD_SUBREAPER]), it is normally attached to the
     system's [init] process, but that should not be the case here).

     Ultimately, the child-child process will run its own executable
     [/proc/self/exe] (in this case, [aussi]) with the argument [__wait] and the
     container state directory that we ultimately want to run.

     In this container state directory, there is a FIFO ([mkfifo]) that the
     process will attempt to read. If it succeeds, it finally launches
     [solo5-hvt] (see the implementation of the [__wait] command in
     [bin/main.ml] here).

     The aim is that as soon as the "runtime" wishes to start ([aussi start]), a
     procedure is required regarding the network interface. Once this is
     complete, we simply need to write to the FIFO to launch the [solo5-hvt]
     process with the correct arguments (properly initialised).

     This is therefore the core of [aussi]. In the case of Linux only, we run
     [aussi __wait] with its state using [unshare(1)] in order to run our
     [solo5-hvt] program in new namespaces (specifically UTS, IPC and NET if
     required). *)
  let intermediate = Unix.fork () in
  if intermediate = 0 then begin
    (* child *)
    Unix.close pid_rd;
    if Unix.fork () <> 0 then exit 0;
    ignore (Unix.setsid ());
    let pid = Unix.getpid () in
    (try
       let s = string_of_int pid ^ "\n" in
       ignore (Unix.write_substring pid_wr s 0 (String.length s))
     with _ -> ());
    inhibit (fun () -> Unix.close pid_wr);
    (* Keep shim's stdio FIFOs inherited so they stay alive across the
       create→start→exec transition (runc init does the same). *)
    let is_linux_root =
      Unix.geteuid () = 0
      && try Sys.is_directory "/proc/self/ns" with _ -> false
    in
    let exe, argv =
      if is_linux_root then
        let ns = [ "--ipc"; "--uts" ] @ if own_netns then [ "--net" ] else [] in
        let args =
          ("unshare" :: ns) @ [ self; "__wait"; Fpath.to_string state_dir ]
        in
        ("unshare", Array.of_list args)
      else
        (* No namespace privileges (no [unshare(1)]). *)
        (self, [| self; "__wait"; Fpath.to_string state_dir |])
    in
    try Unix.execvp exe argv with _ -> exit 127
  end
  else begin
    (* parent *)
    Unix.close pid_wr;
    ignore (Unix.waitpid [] intermediate);
    let ic = Unix.in_channel_of_descr pid_rd in
    let pid = try int_of_string (String.trim (input_line ic)) with _ -> -1 in
    close_in ic;
    if pid < 0 then error_msgf "Failed to spawn placeholder"
    else if own_netns then begin
      (* NOTE(dinosaure): wait for []/proc/<pid>/ns/net] to appear, so [create]
         only returns once Docker can bind-mount the net namespace. *)
      let netns = Fpath.v (Printf.sprintf "/proc/%d/ns/net" pid) in
      let netns_ready () =
        Bos.OS.Path.exists netns |> Result.value ~default:false
      in
      let rec wait n =
        if netns_ready () then true
        else if n <= 0 then false
        else (
          Unix.sleepf 0.01;
          wait (n - 1))
      in
      if wait 50 then Ok pid
      else begin
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        error_msgf "netns placeholder did not expose /proc/%d/ns/net" pid
      end
    end
    else Ok pid
  end

let write_all fd s =
  let len = String.length s in
  let rec go off =
    if off < len then begin
      let n = Unix.write_substring fd s off (len - off) in
      if n > 0 then go (off + n)
    end
  in
  try go 0 with Unix.Unix_error (Unix.EPIPE, _, _) -> ()

let run_hooks hooks state =
  let state_json = State.to_string state |> Result.value ~default:"{}" in
  let run_one (hook : Config.Hooks.entry) =
    Log.info (fun m -> m "running hook: %a" Fpath.pp hook.path);
    try
      let env =
        match hook.env with
        | [] -> Unix.environment ()
        | env -> Array.of_list env
      in
      let args = Array.of_list (Fpath.to_string hook.path :: hook.args) in
      let stdin_rd, stdin_wr = Unix.pipe ~cloexec:false () in
      let pid =
        Unix.create_process_env
          (Fpath.to_string hook.path)
          args env stdin_rd Unix.stdout Unix.stderr
      in
      Unix.close stdin_rd;
      write_all stdin_wr state_json;
      Unix.close stdin_wr;
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED 0 -> Ok ()
      | Unix.WEXITED n ->
          error_msgf "hook %a exited with %d" Fpath.pp hook.path n
      | _ -> error_msgf "hook %a failed" Fpath.pp hook.path
    with Unix.Unix_error (e, _, _) ->
      error_msgf "hook %a: %s" Fpath.pp hook.path (Unix.error_message e)
  in
  List.fold_left
    (fun acc hook ->
      let* () = acc in
      run_one hook)
    (Ok ()) hooks

(* TODO(dinosaure): redirect [stdout] of [solo5-hvt] to the console socket. *)
let setup_console_socket filepath =
  Log.info (fun m -> m "console socket %s requested but Solo5" filepath)

let refresh_state state =
  if state.State.status = Running && state.pid > 0 then
    if not (process_is_alive state.pid) then begin
      let exit_code =
        let path = exit_code_file state.id in
        match Bos.OS.File.read path with
        | Ok content -> int_of_string_opt (String.trim content)
        | Error _ -> collect_exit_status state.pid
      in
      let updated = { state with status= Stopped; pid= 0; exit_code } in
      let _ = save_state updated in
      updated
    end
    else state
  else state

let read_config id =
  match Bos.OS.File.read (config_file id) with
  | Ok content -> Config.of_string content
  | Error _ -> error_msgf "config.json missing for container %s" id

let rootfs_of bundle config =
  if Fpath.is_rel config.Config.root.path then
    Fpath.(bundle // config.root.path)
  else config.Config.root.path

let iface_annotations name (iface : Net.host) =
  let key suffix = "solo5.net." ^ name ^ "." ^ suffix in
  let anns = [ (key "mac", Macaddr.to_string iface.mac) ] in
  let anns =
    match iface.cidr with
    | Some c -> (key "ip", Ipaddr.V4.Prefix.to_string c) :: anns
    | None -> anns
  in
  let anns =
    match iface.cidr6 with
    | Some c -> (key "ipv6", Ipaddr.V6.Prefix.to_string c) :: anns
    | None -> anns
  in
  match iface.gateway with
  | Some gw -> (key "gw", Ipaddr.V4.to_string gw) :: anns
  | None -> anns

let create ~id ~bundle ~pid_file ~console_socket =
  let* bundle =
    if Fpath.is_abs bundle then Ok bundle
    else
      let* cwd = Bos.OS.Dir.current () in
      Ok Fpath.(normalize (cwd // bundle))
  in
  Log.info (fun m -> m "create container %s from bundle %a" id Fpath.pp bundle);
  if Bos.OS.Dir.exists (state_dir id) |> Result.value ~default:false then
    error_msgf "container %s already exists" id
  else begin
    Option.iter setup_console_socket console_socket;
    let config_path = Fpath.(bundle / "config.json") in
    let* _ = Bos.OS.File.must_exist config_path in
    let* str = Bos.OS.File.read config_path in
    let* config = Config.of_string str in
    let rootfs = rootfs_of bundle config in
    let* unikernel = find_unikernel rootfs config.process.args in
    let solo5_defaults =
      match Solo5.load rootfs with
      | None -> []
      | Some (V1 cfg) -> Solo5.V1.to_annotations cfg
    in
    let annotations_initial =
      Solo5.merge_annotations ~defaults:solo5_defaults
        ~overrides:config.annotations
    in
    let netns_explicit = Config.netns config in
    let needs_netns = Config.has_network_namespace config in
    let* manifest = Manifest.query unikernel in
    Log.info (fun m -> m "unikernel manifest:@.%a" Manifest.pp_devices manifest);
    let* () = Manifest.validate manifest annotations_initial in
    let interfaces = Net.parse_interfaces annotations_initial in
    let* () =
      (* NOTE(dinosaure): It is the FIFO that [aussi __wait] will attempt to
         read and that the next call to [aussi start] will fill in order to
         actually launch [solo5-hvt]. *)
      let* _ = Bos.OS.Dir.create ~path:true (state_dir id) in
      let p = Fpath.to_string (exec_fifo id) in
      match Unix.mkfifo p 0o600 with
      | () -> Ok ()
      | exception Unix.Unix_error (Unix.EEXIST, _, _) -> Ok ()
      | exception Unix.Unix_error (e, _, _) ->
          error_msgf "mkfifo %s: %s" p (Unix.error_message e)
    in
    let* placeholder_pid =
      let has_docker_devices =
        List.exists (function Net.Docker _ -> true | _ -> false) interfaces
      in
      let own_netns =
        Unix.geteuid () = 0 && netns_explicit = None && has_docker_devices
      in
      match spawn_placeholder ~own_netns ~state_dir:(state_dir id) with
      | Ok pid ->
          Log.info (fun m ->
              m "spawned placeholder pid=%d (own_netns=%b)" pid own_netns);
          Ok pid
      | Error _ as err -> err
    in
    let netns =
      match netns_explicit with
      | Some _ as p -> p
      | None when needs_netns && placeholder_pid > 0 ->
          Some (Fpath.v (Fmt.str "/proc/%d/ns/net" placeholder_pid))
      | _ -> None
    in
    if interfaces <> [] then
      Log.info (fun m ->
          m "setting up %d network interface(s) in %s" (List.length interfaces)
            (match netns with
            | Some p -> Fmt.str "netns %a" Fpath.pp p
            | None -> "host netns"));
    let result =
      (* NOTE(dinosaure): create tap interfaces. *)
      let* () = Net.setup ?netns interfaces in
      let annotations = annotations_initial in
      let state =
        {
          State.oci_version= config.oci_version
        ; id
        ; status= Created
        ; pid= 0 (* like NULL, it does not matter for now. *)
        ; bundle
        ; annotations
        ; exit_code= None
        ; netns
        }
      in
      let* () = save_state state in
      let* () = Bos.OS.File.write (config_file id) str in
      save_net id interfaces;
      if placeholder_pid > 0 then
        ignore
          (Bos.OS.File.write (placeholder_pid_file id)
             (string_of_int placeholder_pid));
      let* () =
        match pid_file with
        | Some path -> Bos.OS.File.write path (string_of_int placeholder_pid)
        | None -> Ok ()
      in
      (* cgroups *)
      begin match Config.cgroups config with
      | Some oci_path when placeholder_pid > 0 -> begin
          let cg = Cgroup.resolve oci_path in
          match Cgroup.ensure cg with
          | Ok () -> ignore (Cgroup.add_pid cg placeholder_pid)
          | Error (`Msg msg) ->
              Log.warn (fun m -> m "cgroup setup failed: %s" msg)
        end
      | _ -> ()
      end;
      let* () = run_hooks config.hooks.prestart state in
      Log.info (fun m -> m "container %s created" id);
      Ok ()
    in
    match result with
    | Ok () -> Ok ()
    | Error _ as err ->
        (* Clean-up a bit. *)
        Net.teardown ?netns interfaces;
        if placeholder_pid > 0 then begin
          (try Unix.kill placeholder_pid Sys.sigkill
           with Unix.Unix_error _ -> ());
          try ignore (Unix.waitpid [ Unix.WNOHANG ] placeholder_pid)
          with Unix.Unix_error _ -> ()
        end;
        let dir = state_dir id in
        if Bos.OS.Dir.exists dir |> Result.value ~default:false then
          ignore (Bos.OS.Dir.delete ~recurse:true dir);
        err
  end

let start ~id =
  Log.info (fun m -> m "start container %s" id);
  match load_state id with
  | None -> error_msgf "Container %s does not exist" id
  | Some state when state.status <> Created ->
      error_msgf "Container %s is not in created state" id
  | Some state ->
      let* config = read_config id in
      let rootfs = rootfs_of state.bundle config in
      let* unikernel = find_unikernel rootfs config.process.args in
      let interfaces = load_net id in
      let docker_devices =
        List.filter_map
          (function
            | Net.Docker { name; tap; iface; _ } -> Some (name, tap, iface)
            | Net.Tap _ -> None)
          interfaces
        |> List.sort (fun (a, _, _) (b, _, _) -> String.compare a b)
      in
      let* state =
        (* NOTE(dinosaure): This section applies only to Docker. In a Docker
           setup, the required interfaces are only available at the time of
           [aussi start]. This is where we connect the tap interfaces (which we
           prepared during the aussi create] phase) to what Docker provides. *)
        match (state.netns, docker_devices) with
        | None, _ | _, [] -> Ok state
        | Some netns, _ :: _ ->
            let* netns_ifaces = Net.inspect_docker_ifaces netns in
            let by_ifname =
              List.map (fun (i : Net.host) -> (i.ifname, i)) netns_ifaces
            in
            let pair (di_name, di_tap, iface_name) =
              match List.assoc_opt iface_name by_ifname with
              | Some info -> Ok (di_name, di_tap, info)
              | None ->
                  error_msgf
                    "solo5.net.%s pairs with %s but no such interface in the \
                     netns (%s)"
                    di_name iface_name
                    (String.concat ", " (List.map fst by_ifname))
            in
            let* pairs =
              List.fold_left
                (fun acc d ->
                  let* acc = acc in
                  let* p = pair d in
                  Ok (p :: acc))
                (Ok []) docker_devices
              |> Result.map List.rev
            in
            (* NOTE(dinosaure): the name of the bridge must be small. On Linux,
               we have some limitations. *)
            let bridge_of i = Fmt.str "br-aussi-%d" i in
            let* () =
              let _, result =
                List.fold_left
                  (fun (i, acc) (di_name, di_tap, (info : Net.host)) ->
                    let acc =
                      let* () = acc in
                      Log.info (fun m ->
                          m
                            "pairing solo5.net.%s ↔ %s on %s (cidr=%a cidr6=%a \
                             mac=%a gw=%a)"
                            di_name info.ifname (bridge_of i)
                            (Fmt.option Ipaddr.V4.Prefix.pp)
                            info.cidr
                            (Fmt.option Ipaddr.V6.Prefix.pp)
                            info.cidr6 Macaddr.pp info.mac
                            (Fmt.option Ipaddr.V4.pp) info.gateway);
                      Net.bridge_with_iface ~netns ~tap:di_tap
                        ~bridge:(bridge_of i) ~src:info.ifname
                    in
                    (i + 1, acc))
                  (0, Ok ()) pairs
              in
              result
            in
            let new_anns =
              List.concat_map
                (fun (di_name, _, info) -> iface_annotations di_name info)
                pairs
            in
            let annotations =
              Solo5.merge_annotations ~defaults:new_anns
                ~overrides:state.annotations
            in
            let st = { state with State.annotations } in
            let* () = save_state st in
            Ok st
      in
      (* NOTE(dinosaure): we save arguments into a file so that the process
         [aussi __wait] can read it and launch the unikernel correctly. *)
      let extra_argv = resolve_unikernel_argv rootfs state.annotations in
      let hvt_args =
        build_hvt_args ~extra_argv state.annotations interfaces unikernel
          config.process.args
      in
      let argv_lines = Global.solo5_hvt :: hvt_args in
      let argv_blob = String.concat "\n" argv_lines ^ "\n" in
      let* () = Bos.OS.File.write (exec_argv_file id) argv_blob in
      Log.info (fun m ->
          m "signalling wait-wrapper to exec: %s %s" Global.solo5_hvt
            (String.concat " " hvt_args));
      let placeholder_pid =
        match Bos.OS.File.read (placeholder_pid_file id) with
        | Ok s -> int_of_string_opt (String.trim s) |> Option.value ~default:0
        | Error _ -> 0
      in
      if placeholder_pid <= 0 then
        error_msgf "no placeholder PID available; was [create] run as root?"
      else begin
        let fifo = Fpath.to_string (exec_fifo id) in
        (try
           let fd = Unix.openfile fifo [ Unix.O_WRONLY ] 0 in
           (* FIRE! We ask to launch [solo5-hvt] *)
           ignore (Unix.write_substring fd "\000" 0 1);
           Unix.close fd
         with Unix.Unix_error (e, _, _) ->
           Log.warn (fun m -> m "exec.fifo write: %s" (Unix.error_message e)));
        let state =
          { state with State.status= Running; pid= placeholder_pid }
        in
        let* () = save_state state in
        ignore
          (Bos.OS.File.write (internal_pid_file id)
             (string_of_int placeholder_pid));
        let* () = run_hooks config.hooks.poststart state in
        Log.info (fun m ->
            m "container %s started with pid %d (post-exec)" id placeholder_pid);
        Ok ()
      end

let run ~id ~bundle ~pid_file ~console_socket =
  match create ~id ~bundle ~pid_file ~console_socket with
  | Error _ as e -> e
  | Ok () -> start ~id

let state ~id =
  match load_state id with
  | None -> error_msgf "container %s does not exist" id
  | Some state -> (
      let state = refresh_state state in
      match State.to_string state with
      | Ok json -> Ok json
      | Error (`Msg msg) -> error_msgf "failed to encode state: %s" msg)

let kill ~id ~signal =
  Log.info (fun m -> m "kill container %s with signal %d" id signal);
  match load_state id with
  | None -> error_msgf "container %s does not exist" id
  | Some state when state.status = Stopped -> Ok ()
  | Some state ->
      let placeholder_pid =
        match Bos.OS.File.read (placeholder_pid_file id) with
        | Ok s -> int_of_string_opt (String.trim s) |> Option.value ~default:0
        | Error _ -> 0
      in
      let try_signal pid =
        if pid > 0 then try Unix.kill pid signal with Unix.Unix_error _ -> ()
      in
      (* kill [solo5-hvt] *)
      try_signal state.pid;
      (* or kill [aussi __wait] *)
      if placeholder_pid <> state.pid then try_signal placeholder_pid;
      Ok ()

let delete ~id ~force =
  Log.info (fun m -> m "delete container %s" id);
  match load_state id with
  | None -> error_msgf "container %s does not exist" id
  | Some state ->
      let state = refresh_state state in
      let try_kill_and_wait pid =
        (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
        let rec wait n =
          if n <= 0 then ()
          else if not (process_is_alive pid) then ()
          else (
            Unix.sleepf 0.02;
            wait (n - 1))
        in
        wait 100
      in
      let placeholder_pid =
        match Bos.OS.File.read (placeholder_pid_file id) with
        | Ok s -> int_of_string_opt (String.trim s) |> Option.value ~default:0
        | Error _ -> 0
      in
      let* () =
        if state.status = Running then
          if force then begin
            try_kill_and_wait state.pid;
            if placeholder_pid > 0 && placeholder_pid <> state.pid then
              try_kill_and_wait placeholder_pid;
            Ok ()
          end
          else error_msgf "container %s is still running, use --force" id
        else begin
          if state.pid > 0 then try_kill_and_wait state.pid;
          if placeholder_pid > 0 && placeholder_pid <> state.pid then
            try_kill_and_wait placeholder_pid;
          Ok ()
        end
      in
      begin match read_config id with
      | Ok config ->
          begin match run_hooks config.hooks.poststop state with
          | Ok () -> ()
          | Error (`Msg msg) -> Log.warn (fun m -> m "poststop hook: %s" msg)
          end
      | Error _ -> ()
      end;
      (* Clean-up interfaces. *)
      let interfaces = load_net id in
      begin match state.netns with
      | Some _ -> ()
      | None ->
          if interfaces <> [] then begin
            Log.info (fun m ->
                m "tearing down %d host network interface(s)"
                  (List.length interfaces));
            Net.teardown interfaces
          end
      end;
      (* Clean-up cgroups. *)
      begin match read_config id with
      | Ok config ->
          begin match Config.cgroups config with
          | Some oci_path -> Cgroup.remove (Cgroup.resolve oci_path)
          | None -> ()
          end
      | Error _ -> ()
      end;
      (* Clean-up state directory. *)
      let dir = state_dir id in
      if Bos.OS.Dir.exists dir |> Result.value ~default:false then
        ignore (Bos.OS.Dir.delete ~recurse:true dir);
      Log.info (fun m -> m "container %s deleted" id);
      Ok ()

let list () =
  let root = Global.get_root () in
  if not (Bos.OS.Dir.exists root |> Result.value ~default:false) then Ok []
  else begin
    let* entries = Bos.OS.Dir.contents root in
    let fn path =
      let id = Fpath.basename path in
      match load_state id with
      | Some state -> Some (refresh_state state)
      | None -> None
    in
    Ok (List.filter_map fn entries)
  end

let solo5 = Domain_name.(host_exn (of_string_exn "solo5"))

let spec () =
  let config : Config.t =
    {
      oci_version= "1.0.0"
    ; process=
        {
          args= [ "unikernel.hvt" ]
        ; env= []
        ; cwd= Fpath.v "/"
        ; terminal= false
        }
    ; root= { path= Fpath.v "rootfs"; readonly= true }
    ; hostname= Some solo5
    ; annotations=
        [
          ("solo5.mem", "512"); ("solo5.net.service", "tap100")
        ; ("solo5.net.service.ip", "10.0.0.1/24")
        ]
    ; hooks= Config.Hooks.empty
    ; linux= None
    }
  in
  match Config.to_string config with
  | Ok json -> Ok json
  | Error (`Msg msg) -> error_msgf "Failed to generate spec: %s" msg

type features_doc = {
    oci_version_min: string
  ; oci_version_max: string
  ; hooks: string list
  ; mount_options: string list
  ; annotations: (string * string) list
}

let features =
  let open Jsont in
  Object.map ~kind:"features"
    (fun oci_version_min oci_version_max hooks mount_options annotations ->
      { oci_version_min; oci_version_max; hooks; mount_options; annotations })
  |> Object.mem "ociVersionMin" Jsont.string ~enc:(fun f -> f.oci_version_min)
  |> Object.mem "ociVersionMax" Jsont.string ~enc:(fun f -> f.oci_version_max)
  |> Object.mem "hooks" Jsont.(list string) ~enc:(fun f -> f.hooks)
  |> Object.mem "mountOptions"
       Jsont.(list string)
       ~enc:(fun f -> f.mount_options)
  |> Object.mem "annotations" Config.annotations ~enc:(fun f -> f.annotations)
  |> Object.finish

let features () =
  let doc =
    {
      oci_version_min= "1.0.0"
    ; oci_version_max= "1.2.0"
    ; hooks= [ "prestart"; "poststart"; "poststop" ]
    ; mount_options= []
    ; annotations=
        [
          ("solo5.mem", "Guest memory in MB")
        ; ("solo5.net.<name>", "Host tap interface backing a Solo5 net device")
        ; ("solo5.net.<name>.ip", "IPv4 address in CIDR notation")
        ; ("solo5.net.<name>.ipv6", "IPv6 address in CIDR notation")
        ; ("solo5.net.<name>.gw", "IPv4 default gateway")
        ; ("solo5.net.<name>.mac", "Guest MAC address")
        ; ( "solo5.net.<name>.docker"
          , "Interface name inside the container netns to bridge with (eth0, \
             eth1, ...)" )
        ; ( "solo5.block.<name>"
          , "Host path of the file backing a Solo5 block device" )
        ; ( "solo5.block.<name>.sector-size"
          , "Sector size in bytes for the block device" )
        ; ( "solo5.cmdline"
          , "Whitespace-separated unikernel argv template (annotations \
             expanded)" )
        ]
    }
  in
  match Jsont_bytesrw.encode_string ~format:Jsont.Indent features doc with
  | Ok _ as v -> v
  | Error msg -> error_msgf "Failed to encode features: %s" msg
