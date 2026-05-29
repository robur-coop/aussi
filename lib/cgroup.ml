let src = Logs.Src.create "aussi.cgroup" ~doc:"OCI cgroup placement"
let error_msgf fmt = Fmt.kstr (fun msg -> Error (`Msg msg)) fmt

module Log = (val Logs.src_log src)

let root = Fpath.v "/sys/fs/cgroup"

let resolve oci =
  if String.contains oci ':' then
    match String.split_on_char ':' oci with
    | [ slice; prefix; name ] ->
        let scope = Fmt.str "%s-%s.scope" prefix name in
        Fpath.(root / slice / scope)
    | _ -> Fpath.(root // v oci)
  else
    let trimmed =
      if String.length oci > 0 && oci.[0] = '/' then
        String.sub oci 1 (String.length oci - 1)
      else oci
    in
    Fpath.(root // v trimmed)

let ensure cg =
  match Bos.OS.Dir.create ~path:true cg with
  | Ok _ -> Ok ()
  | Error (`Msg msg) -> error_msgf "Cgroup mkdir: %s" msg

let add_pid cg pid =
  let procs = Fpath.(cg / "cgroup.procs") in
  match
    let s = Fpath.to_string procs in
    let oc = open_out_gen [ Open_append; Open_wronly ] 0o644 s in
    let finally () = close_out oc in
    Fun.protect ~finally @@ fun () -> output_string oc (string_of_int pid ^ "\n")
  with
  | () ->
      Log.info (fun m -> m "Added pid %d to %a" pid Fpath.pp cg);
      Ok ()
  | exception Sys_error msg -> error_msgf "Cgroup.add_pid: %s" msg

let remove cg =
  match Unix.rmdir (Fpath.to_string cg) with
  | () -> Log.info (fun m -> m "Removed %a" Fpath.pp cg)
  | exception Unix.Unix_error (err, _, _) ->
      Log.warn (fun m ->
          m "Cgroup.remove %a: %s" Fpath.pp cg (Unix.error_message err))
