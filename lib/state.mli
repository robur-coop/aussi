(** The OCI container state, as reported by [aussi state] and persisted to
    [state.json] in the container's state directory. *)

(** Container lifecycle status, following the OCI runtime state schema. *)
type status =
  | Creating
  | Created  (** After {!Runtime.create}, before {!Runtime.start}. *)
  | Running  (** solo5-hvt is alive. *)
  | Stopped  (** solo5-hvt has exited; see {!field:exit_code}. *)

type t = {
    oci_version: string
  ; id: string  (** Container identifier. *)
  ; status: status
  ; pid: int  (** solo5-hvt pid while {!Running}, [0] otherwise. *)
  ; bundle: Fpath.t  (** Path to the OCI bundle. *)
  ; annotations: (string * string) list
  ; exit_code: int option
        (** Set once {!Stopped}; [128 + signal] for signalled exits. *)
  ; netns: Fpath.t option
        (** Bind-mount path of a pre-built network namespace (set when Docker's
            [--network=bridge] is in use). When [Some], {!Runtime} runs
            [solo5-hvt] inside that netns via [nsenter]. *)
}

val to_string : t -> (string, [> `Msg of string ]) result
(** [to_string s] encodes [s] as an indented OCI state document. *)

val of_string : string -> (t, [> `Msg of string ]) result
(** [of_string s] decodes an OCI state document. *)
