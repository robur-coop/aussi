let error_msgf fmt = Fmt.kstr (fun msg -> Error (`Msg msg)) fmt

open Cmdliner

let existing_directory =
  let parser str =
    match Fpath.of_string str with
    | Ok v when Sys.file_exists str && Sys.is_directory str ->
        Ok (Fpath.to_dir_path v)
    | Ok v -> error_msgf "%a does not exist (or is not a directory)" Fpath.pp v
    | Error _ as err -> err
  in
  Arg.conv (parser, Fpath.pp)

let possibly_existing_file = Arg.conv (Fpath.of_string, Fpath.pp)

let signal =
  let names =
    [
      ("HUP", Sys.sighup); ("INT", Sys.sigint); ("QUIT", Sys.sigquit)
    ; ("KILL", Sys.sigkill); ("USR1", Sys.sigusr1); ("USR2", Sys.sigusr2)
    ; ("TERM", Sys.sigterm); ("STOP", Sys.sigstop); ("CONT", Sys.sigcont)
    ]
  in
  let parser str =
    match int_of_string_opt str with
    | Some n -> Ok n
    | None -> (
        let key = String.uppercase_ascii str in
        let key =
          if String.length key > 3 && String.sub key 0 3 = "SIG" then
            String.sub key 3 (String.length key - 3)
          else key
        in
        match List.assoc_opt key names with
        | Some n -> Ok n
        | None -> error_msgf "unknown signal: %s" str)
  in
  let pp ppf n =
    match List.find_opt (fun (_, s) -> s = n) names with
    | Some (name, _) -> Fmt.string ppf name
    | None -> Fmt.int ppf n
  in
  Arg.conv (parser, pp)

let root =
  let open Arg in
  value
  & opt existing_directory (Fpath.v "/run/aussi/")
  & info [ "root" ] ~docv:"PATH"
      ~doc:
        "Root directory for container state. Defaults to /run/aussi. Can also \
         be set via AUSSI_STATE."

let file_reporter_installed = ref false

let setup_log =
  let setup style_renderer level =
    Fmt_tty.setup_std_outputs ?style_renderer ();
    Logs.set_level level;
    if not !file_reporter_installed then
      Logs.set_reporter (Logs_fmt.reporter ())
  in
  Term.(const setup $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let log_file =
  let open Arg in
  value
  & opt (some string) None
  & info [ "log" ] ~docv:"PATH"
      ~doc:"Log file path. If set, logs are written to this file."

let log_format =
  let open Arg in
  value
  & opt string "text"
  & info [ "log-format" ] ~docv:"FORMAT"
      ~doc:"Log format: text or json (default: text)."

let escape s =
  let buf = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string buf {|\"|}
      | '\\' -> Buffer.add_string buf {|\\|}
      | '\n' -> Buffer.add_string buf {|\n|}
      | '\r' -> Buffer.add_string buf {|\r|}
      | '\t' -> Buffer.add_string buf {|\t|}
      | c when Char.code c < 0x20 ->
          Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char buf c)
    s;
  Buffer.contents buf

let now () =
  Fmt.str "%a"
    (Ptime.pp_rfc3339 ~frac_s:9 ~tz_offset_s:0 ())
    (Ptime_clock.now ())

let setup_log_io ~path ~format =
  let oc = open_out_gen [ Open_append; Open_creat ] 0o644 path in
  let fmt = Format.formatter_of_out_channel oc in
  let reporter =
    if format = "json" then
      let json_report _src level ~over k msgf =
        let time = now () in
        let level_str =
          match level with
          | Logs.App -> "info"
          | Logs.Error -> "error"
          | Logs.Warning -> "warning"
          | Logs.Info -> "info"
          | Logs.Debug -> "debug"
        in
        msgf @@ fun ?header:_ ?tags:_ msg ->
        let mbuf = Buffer.create 64 in
        let mfmt = Format.formatter_of_buffer mbuf in
        (* NOTE(dinosaure): we do [Fmt.* mfmt msg], the result is recorded into
           [mbuf] and, at the end, we flush and print into [fmt]/[oc]. *)
        Fmt.kpf
          (fun _ ->
            Format.pp_print_flush mfmt ();
            let escaped = escape (Buffer.contents mbuf) in
            Fmt.pf fmt "{\"time\":\"%s\",\"level\":\"%s\",\"msg\":\"%s\"}@."
              time level_str escaped;
            over ();
            k ())
          mfmt msg
      in
      Logs.{ report= json_report }
    else Logs_fmt.reporter ~dst:fmt ()
  in
  Logs.set_reporter reporter;
  file_reporter_installed := true

let setup_global () _root log_file_opt log_format_opt =
  begin match Sys.getenv_opt "AUSSI_STATE" with
  | Some v when Sys.file_exists v && Sys.is_directory v ->
      Option.iter Aussi.Runtime.Global.set_root
        (Result.to_option (Fpath.of_string v))
  | _ -> ()
  end;
  match log_file_opt with
  | Some path -> setup_log_io ~path ~format:log_format_opt
  | None -> ()

let global_opts =
  Term.(const setup_global $ setup_log $ root $ log_file $ log_format)

let run_result = function
  | Ok () -> `Ok ()
  | Error (`Msg msg) -> `Error (false, msg)

let exits = Cmd.Exit.defaults

let man_xrefs =
  [
    `Tool "solo5-hvt"; `Tool "solo5-elftool"; `Tool "runc"; `Tool "docker"
  ; `Page ("containerd", 1); `Main
  ]

let envs =
  [
    Cmd.Env.info "SOLO5_HVT"
      ~doc:"Path to the $(b,solo5-hvt) tender. Defaults to $(b,solo5-hvt)."
  ; Cmd.Env.info "SOLO5_ELFTOOL"
      ~doc:
        "Path to $(b,solo5-elftool), used to read the unikernel manifest. \
         Defaults to $(b,solo5-elftool)."
  ; Cmd.Env.info "AUSSI_STATE"
      ~doc:
        "Directory holding per-container state. Defaults to $(b,/run/aussi). \
         Must be an existing directory; equivalent to the global $(b,--root) \
         option."
  ]

let cmd_man description =
  (`S Manpage.s_description :: description)
  @ [
      `S "ANNOTATIONS"
    ; `P
        "Solo5 devices are configured through OCI annotations (see \
         $(b,aussi)(1) for the full list), e.g. $(b,solo5.mem), \
         $(b,solo5.net.<name>) and $(b,solo5.block.<name>)."
    ]

let create_cmd =
  let id =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"CONTAINER_ID")
  in
  let bundle =
    let open Arg in
    value
    & opt existing_directory (Fpath.v "./")
    & info [ "bundle"; "b" ] ~docv:"PATH"
        ~doc:"Path to the OCI bundle directory."
  in
  let pid_file =
    let open Arg in
    value
    & opt (some possibly_existing_file) None
    & info [ "pid-file" ] ~docv:"PATH"
        ~doc:"Write the container PID to this file."
  in
  let console_socket =
    let open Arg in
    value
    & opt (some string) None
    & info [ "console-socket" ] ~docv:"PATH"
        ~doc:"Unix socket path for console PTY."
  in
  let run () id bundle pid_file console_socket =
    run_result (Aussi.Runtime.create ~id ~bundle ~pid_file ~console_socket)
  in
  let info =
    Cmd.info "create" ~doc:"Create a Solo5 container." ~exits ~envs ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Create a new container from an OCI bundle. The container's \
                rootfs must contain a $(b,.hvt) unikernel binary (selected by \
                $(b,process.args) or auto-detected). The unikernel manifest is \
                validated against the configured annotations and the network \
                is set up, but the unikernel is not launched until $(b,aussi \
                start) is called."; `S Manpage.s_examples
           ; `Pre "  aussi create --bundle ./bundle mycontainer"
           ])
  in
  let term =
    let open Term in
    ret (const run $ global_opts $ id $ bundle $ pid_file $ console_socket)
  in
  Cmd.v info term

let start_cmd =
  let id =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"CONTAINER_ID")
  in
  let run () id = run_result (Aussi.Runtime.start ~id) in
  let info =
    Cmd.info "start" ~doc:"Start a Solo5 container." ~exits ~envs ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Launch $(b,solo5-hvt) for a previously $(b,created) container. \
                A detached supervisor becomes the parent of the tender; the \
                command returns only once the $(i,running) state has been \
                persisted."; `S Manpage.s_examples
           ; `Pre "  aussi start mycontainer"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts $ id))

let run_cmd =
  let id =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"CONTAINER_ID")
  in
  let bundle =
    let open Arg in
    value
    & opt existing_directory (Fpath.v "./")
    & info [ "bundle"; "b" ] ~docv:"PATH"
        ~doc:"Path to the OCI bundle directory."
  in
  let pid_file =
    let open Arg in
    value
    & opt (some possibly_existing_file) None
    & info [ "pid-file" ] ~docv:"PATH"
        ~doc:"Write the container PID to this file."
  in
  let console_socket =
    let open Arg in
    value
    & opt (some string) None
    & info [ "console-socket" ] ~docv:"PATH"
        ~doc:"Unix socket path for console PTY."
  in
  let run () id bundle pid_file console_socket =
    run_result (Aussi.Runtime.run ~id ~bundle ~pid_file ~console_socket)
  in
  let info =
    Cmd.info "run"
      ~doc:"Create and start a Solo5 container (convenience command)." ~exits
      ~envs ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Equivalent to $(b,aussi create) immediately followed by \
                $(b,aussi start)."; `S Manpage.s_examples
           ; `Pre "  aussi run --bundle ./bundle mycontainer"
           ])
  in
  let term =
    let open Term in
    ret (const run $ global_opts $ id $ bundle $ pid_file $ console_socket)
  in
  Cmd.v info term

let state_cmd =
  let id =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"CONTAINER_ID")
  in
  let run () id =
    match Aussi.Runtime.state ~id with
    | Ok json -> print_string json; print_newline (); `Ok ()
    | Error (`Msg msg) -> `Error (false, msg)
  in
  let info =
    Cmd.info "state" ~doc:"Query a Solo5 container state." ~exits ~envs
      ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Print the OCI state of the container as a JSON document on \
                standard output. The status is reconciled on a best-effort \
                basis if the unikernel has exited."; `S Manpage.s_examples
           ; `Pre "  aussi state mycontainer"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts $ id))

let kill_cmd =
  let id =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"CONTAINER_ID")
  in
  let signal =
    let open Arg in
    value
    & pos 1 signal Sys.sigterm
    & info [] ~docv:"SIGNAL"
        ~doc:"Signal number or name (e.g. 9, KILL, SIGKILL; default: TERM)."
  in
  (* NOTE(dinosaure): it seems that Docker add the [--all] flag when we fail to
    setup. So we must handle this argument. *)
  let all =
    let open Arg in
    value
    & flag
    & info [ "all"; "a" ]
        ~doc:"Send signal to all processes (runc compat; no-op for Solo5)."
  in
  let run () id signal _all = run_result (Aussi.Runtime.kill ~id ~signal) in
  let info =
    Cmd.info "kill" ~doc:"Send a signal to a Solo5 container." ~exits ~envs
      ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Send $(i,SIGNAL) to the running unikernel. $(i,SIGNAL) may be \
                a number ($(b,9)) or a name, with or without the $(b,SIG) \
                prefix ($(b,KILL), $(b,SIGKILL)). Defaults to $(b,TERM)."
           ; `S Manpage.s_examples
           ; `Pre "  aussi kill mycontainer KILL\n  aussi kill mycontainer 9"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts $ id $ signal $ all))

let delete_cmd =
  let id =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"CONTAINER_ID")
  in
  let force =
    let open Arg in
    value
    & flag
    & info [ "force"; "f" ]
        ~doc:"Kill the unikernel first if the container is still running."
  in
  let run () id force = run_result (Aussi.Runtime.delete ~id ~force) in
  let info =
    Cmd.info "delete" ~doc:"Delete a Solo5 container." ~exits ~envs ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Run the poststop hooks, tear down the network interfaces and \
                remove the container state. A running container is rejected \
                unless $(b,--force) is given."; `S Manpage.s_examples
           ; `Pre "  aussi delete --force mycontainer"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts $ id $ force))

let list_cmd =
  let run () =
    match Aussi.Runtime.list () with
    | Error (`Msg msg) -> `Error (false, msg)
    | Ok containers ->
        Fmt.pr "%-40s %-10s %-8s %s\n" "ID" "STATUS" "PID" "BUNDLE";
        List.iter
          (fun (st : Aussi.State.t) ->
            let status =
              match st.status with
              | Creating -> "creating"
              | Created -> "created"
              | Running -> "running"
              | Stopped -> "stopped"
            in
            let pid = if st.pid > 0 then string_of_int st.pid else "-" in
            Fmt.pr "%-40s %-10s %-8s %a\n" st.id status pid Fpath.pp st.bundle)
          containers;
        `Ok ()
  in
  let info =
    Cmd.info "list" ~doc:"List all Solo5 containers." ~exits ~envs ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Print one line per known container with its id, status, pid \
                and bundle path."; `S Manpage.s_examples; `Pre "  aussi list"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts))

let spec_cmd =
  let run () =
    match Aussi.Runtime.spec () with
    | Ok json -> print_string json; print_newline (); `Ok ()
    | Error (`Msg msg) -> `Error (false, msg)
  in
  let info =
    Cmd.info "spec"
      ~doc:"Generate a template config.json for a Solo5 unikernel." ~exits ~envs
      ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Print a template OCI $(b,config.json) on standard output, \
                pre-filled with example Solo5 annotations."
           ; `S Manpage.s_examples; `Pre "  aussi spec > config.json"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts))

(* Our internal [aussi __wait] command. *)

let is_pipe_or_socket fd =
  match (Unix.fstat fd).Unix.st_kind with
  | Unix.S_FIFO | Unix.S_SOCK -> true
  | _ -> false

let plug_to_file dir =
  if not (is_pipe_or_socket Unix.stdout) then
    begin try
      let log = Fpath.to_string Fpath.(dir / "console.log") in
      let fd =
        Unix.openfile log [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND ] 0o644
      in
      Unix.dup2 fd Unix.stdout;
      Unix.dup2 fd Unix.stderr;
      if fd <> Unix.stdout && fd <> Unix.stderr then Unix.close fd
    with Unix.Unix_error (err, _, _) ->
      Fmt.epr "aussi __wait: console.log: %s\n%!" (Unix.error_message err)
    end

let wait_cmd =
  let state_dir =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"STATE_DIR")
  in
  let run () state_dir =
    let dir = Fpath.v state_dir in
    let fifo = Fpath.to_string Fpath.(dir / "exec.fifo") in
    let argv_path = Fpath.to_string Fpath.(dir / "exec.argv") in
    (try
       let fd = Unix.openfile fifo [ Unix.O_RDONLY ] 0 in
       let buf = Bytes.create 1 in
       ignore (Unix.read fd buf 0 1);
       Unix.close fd
     with Unix.Unix_error (e, _, _) ->
       Fmt.epr "aussi __wait: open %s: %s\n%!" fifo (Unix.error_message e);
       exit Cmd.Exit.internal_error);
    let argv =
      try
        let ic = open_in argv_path in
        let lines = ref [] in
        (try
           while true do
             lines := input_line ic :: !lines
           done
         with End_of_file -> ());
        close_in ic; List.rev !lines
      with Sys_error msg ->
        Fmt.epr "aussi __wait: read %s: %s\n%!" argv_path msg;
        exit Cmd.Exit.internal_error
    in
    match argv with
    | [] ->
        Fmt.epr "aussi __wait: empty argv\n%!";
        `Error (false, "empty argv")
    | exe :: _ -> begin
        plug_to_file dir;
        let arr = Array.of_list argv in
        try Unix.execvp exe arr
        with Unix.Unix_error (e, _, _) ->
          Fmt.epr "aussi __wait: execvp %s: %s\n%!" exe (Unix.error_message e);
          exit 127
      end
  in
  let info =
    Cmd.info "__wait"
      ~doc:"Internal: block on exec.fifo, then exec the recorded argv."
  in
  Cmd.v info Term.(ret (const run $ global_opts $ state_dir))

let features_cmd =
  let run () =
    match Aussi.Runtime.features () with
    | Ok json -> print_string json; print_newline (); `Ok ()
    | Error (`Msg msg) -> `Error (false, msg)
  in
  let info =
    Cmd.info "features" ~doc:"Print the OCI runtime features document." ~exits
      ~envs ~man_xrefs
      ~man:
        (cmd_man
           [
             `P
               "Print a JSON document describing the OCI runtime features \
                supported by $(b,aussi): the OCI runtime-spec version range, \
                the lifecycle hooks honoured by \
                $(b,create)/$(b,start)/$(b,delete), and the recognised \
                $(b,solo5.*) annotations. Mirrors $(b,runc features); used by \
                Docker/containerd to discover runtime capabilities."
           ; `S Manpage.s_examples; `Pre "  aussi features"
           ])
  in
  Cmd.v info Term.(ret (const run $ global_opts))

(* NOTE(dinosaure): pre-parse --root, --log, --log-format, --systemd-cgroup
   before cmdliner sees them. containerd passes these before the subcommand:
     aussi --root /path --log /path --log-format json create ...
   cmdliner's [Cmd.group] doesn't accept flags before the subcommand, so we
   extract and apply them ourselves, then strip them from argv. *)

let has_prefix p s =
  String.length s >= String.length p && String.sub s 0 (String.length p) = p

let strip_prefix p s =
  String.sub s (String.length p) (String.length s - String.length p)

let preparse_global_args () =
  let argv = Array.to_list Sys.argv in
  let log_path = ref None in
  let log_format = ref "text" in
  let apply_root v =
    match Fpath.of_string v with
    | Ok p ->
        begin match Bos.OS.Dir.create ~path:true p with
        | Ok _ -> Aussi.Runtime.Global.set_root p
        | Error (`Msg msg) -> Logs.warn (fun m -> m "mkdir --root: %s" msg)
        end
    | Error (`Msg msg) -> Logs.warn (fun m -> m "invalid --root %s: %s" v msg)
  in
  let rec scan acc = function
    | [] -> List.rev acc
    | "--root" :: v :: rest -> apply_root v; scan acc rest
    | s :: rest when has_prefix "--root=" s ->
        apply_root (strip_prefix "--root=" s);
        scan acc rest
    | "--log" :: v :: rest ->
        log_path := Some v;
        scan acc rest
    | s :: rest when has_prefix "--log=" s ->
        log_path := Some (strip_prefix "--log=" s);
        scan acc rest
    | "--log-format" :: v :: rest ->
        log_format := v;
        scan acc rest
    | s :: rest when has_prefix "--log-format=" s ->
        log_format := strip_prefix "--log-format=" s;
        scan acc rest
    | "--systemd-cgroup" :: rest ->
        (* containerd passes this; ignore silently *)
        scan acc rest
    | x :: rest -> scan (x :: acc) rest
  in
  let filtered = scan [] argv in
  begin match !log_path with
  | Some path -> setup_log_io ~path ~format:!log_format
  | None -> ()
  end;
  Array.of_list filtered

let () =
  Printexc.record_backtrace true;
  let argv =
    try preparse_global_args ()
    with exn ->
      Printf.eprintf "aussi: preparse failed: %s\n%!" (Printexc.to_string exn);
      exit Cmd.Exit.internal_error
  in
  let info =
    Cmd.info "aussi" ~version:"0.1.0" ~doc:"OCI runtime for Solo5 unikernels."
      ~exits ~envs ~man_xrefs
      ~man:
        [
          `S Manpage.s_description
        ; `P
            "$(tname) is an OCI-compatible container runtime that launches \
             Solo5 unikernels with $(b,solo5-hvt) instead of standard Linux \
             containers. It implements the same interface as $(b,runc) and can \
             therefore be plugged into Docker, containerd or Podman, as well \
             as driven directly with an OCI bundle."
        ; `P
            "OCI verbs are separate, short-lived invocations. $(b,start) \
             spawns a detached supervisor that parents $(b,solo5-hvt), records \
             its exit code and flips the container to $(i,stopped) when it \
             dies."; `S "ANNOTATIONS"
        ; `P
            "Solo5 devices are configured via OCI annotations, optionally \
             defaulted by a $(b,solo5.json) file inside the rootfs (runtime \
             annotations take precedence):"
        ; `I ("$(b,solo5.mem)", "Guest memory in MB (default: 512).")
        ; `I
            ( "$(b,solo5.net.<name>)"
            , "Host TAP interface backing the Solo5 network device $(i,name) \
               (auto-generated as $(b,v<name>) when absent)." )
        ; `I
            ( "$(b,solo5.net.<name>.ip)"
            , "IPv4 address for $(i,name) in CIDR notation." )
        ; `I
            ( "$(b,solo5.net.<name>.ipv6)"
            , "IPv6 address for $(i,name) in CIDR notation." )
        ; `I
            ( "$(b,solo5.net.<name>.gw)"
            , "IPv4 default gateway for $(i,name). The IPv6 default route is \
               left to router advertisements." )
        ; `I ("$(b,solo5.net.<name>.mac)", "Guest MAC address for $(i,name).")
        ; `I
            ( "$(b,solo5.net.<name>.docker)"
            , "Interface name inside the container's netns ($(b,eth0), \
               $(b,eth1), ...) to bridge $(i,name) with when running under \
               $(b,docker run --network=bridge)." )
        ; `I
            ( "$(b,solo5.block.<name>)"
            , "Host path of the file backing the block device $(i,name)." )
        ; `I
            ( "$(b,solo5.block.<name>.sector-size)"
            , "Sector size in bytes for $(i,name), passed to $(b,solo5-hvt) as \
               $(b,--block-sector-size:<name>=<size>)." )
        ; `I
            ( "$(b,solo5.cmdline)"
            , "Whitespace-separated unikernel argv template. Overrides the \
               image author's $(b,argv) list in $(b,solo5.json). Each token \
               may contain $(b,%{annotation.key}) placeholders, resolved \
               against the (merged) annotations and appended to the \
               unikernel's arguments. This is how OCI/orchestrator inputs that \
               have no $(b,solo5-hvt) equivalent are passed to the unikernel."
            ); `S Manpage.s_examples
        ; `P "Run a unikernel directly from an OCI bundle:"
        ; `Pre
            "  aussi create --bundle ./bundle web\n\
            \  aussi start web\n\
            \  aussi state web\n\
            \  aussi delete --force web"
        ; `P "Or through Docker once registered as a runtime:"
        ; `Pre "  docker run --rm --runtime=solo5 my-unikernel"
        ; `S Manpage.s_bugs
        ; `P "Report issues at $(i,https://github.com/dinosaure/aussi/issues)."
        ]
  in
  let cmd =
    Cmd.group info
      [
        create_cmd; start_cmd; run_cmd; state_cmd; kill_cmd; delete_cmd
      ; list_cmd; spec_cmd; features_cmd; wait_cmd
      ]
  in
  let code =
    try Cmd.eval ~argv ~catch:false cmd
    with exn ->
      let bt = Printexc.get_backtrace () in
      Logs.err (fun m ->
          m "uncaught exception: %s%s%s" (Printexc.to_string exn)
            (if bt = "" then "" else " | ")
            bt);
      Fmt.epr "aussi: uncaught exception: %s\n%s%!" (Printexc.to_string exn) bt;
      Cmd.Exit.internal_error
  in
  exit code
