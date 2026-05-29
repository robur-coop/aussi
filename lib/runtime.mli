(** OCI runtime operations for Solo5 unikernels.

    Each function implements one OCI runtime verb. State is persisted under a
    root directory (default [/run/aussi/], see {!Global}), one sub-directory per
    container holding [state.json], [config.json], [net.json], the log files and
    the recorded exit code.

    {2 Process model}

    {!start} launches [solo5-hvt] under a {e detached supervisor}: [start]
    double-forks a session-leader process that becomes the real parent of
    [solo5-hvt], so the unikernel survives the short-lived runtime invocation.
    The supervisor records the exit code and flips the state to {!State.Stopped}
    when [solo5-hvt] dies; {!state} and {!list} also reconcile state on a
    best-effort basis if the supervisor was itself killed. *)

(** Location of the container state root. *)
module Global : sig
  val get_root : unit -> Fpath.t
  (** [get_root ()] is the current state root (default [/run/aussi/]). *)

  val set_root : Fpath.t -> unit
  (** [set_root p] overrides the state root (e.g. from [--root] or
      [AUSSI_STATE]). *)

  val solo5_hvt : string
  (** The [solo5-hvt] executable, from [$SOLO5_HVT] or ["solo5-hvt"]. *)
end

val create :
     id:string
  -> bundle:Fpath.t
  -> pid_file:Fpath.t option
  -> console_socket:string option
  -> (unit, [> `Msg of string ]) result
(** [create ~id ~bundle ~pid_file ~console_socket] reads [bundle/config.json],
    locates the [.hvt] unikernel, merges [solo5.json] defaults, validates the
    manifest against the annotations, sets up the network and persists the
    {!State.Created} state. The network is torn down if setup fails. Fails if a
    container with [id] already exists. *)

val start : id:string -> (unit, [> `Msg of string ]) result
(** [start ~id] launches [solo5-hvt] under the detached supervisor and moves the
    container to {!State.Running}. The container must be {!State.Created}. *)

val run :
     id:string
  -> bundle:Fpath.t
  -> pid_file:Fpath.t option
  -> console_socket:string option
  -> (unit, [> `Msg of string ]) result
(** [run] is [create] followed by [start]. *)

val state : id:string -> (string, [> `Msg of string ]) result
(** [state ~id] returns the (refreshed) OCI state as a JSON document. *)

val kill : id:string -> signal:int -> (unit, [> `Msg of string ]) result
(** [kill ~id ~signal] sends [signal] to [solo5-hvt]. The container must be
    {!State.Running}. *)

val delete : id:string -> force:bool -> (unit, [> `Msg of string ]) result
(** [delete ~id ~force] runs the poststop hooks, tears down the network and
    removes the state directory. A running container is rejected unless [force]
    is set, in which case it is [SIGKILL]ed first. *)

val list : unit -> (State.t list, [> `Msg of string ]) result
(** [list ()] returns the (refreshed) state of every known container. *)

val spec : unit -> (string, [> `Msg of string ]) result
(** [spec ()] returns a template [config.json] for a Solo5 unikernel. *)

val features : unit -> (string, [> `Msg of string ]) result
(** [features ()] returns the OCI runtime features document as JSON, describing
    the OCI version range, supported hooks and the recognised [solo5.*]
    annotations. Mirrors [runc features]. *)
