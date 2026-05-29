(** Best-effort cgroup placement for the OCI [linux.cgroupsPath]. *)

val resolve : string -> Fpath.t
(** [resolve oci] turns an OCI [linux.cgroupsPath] into a filesystem path under
    [/sys/fs/cgroup].

    - ["slice:prefix:name"] (systemd) ->
      ["/sys/fs/cgroup/<slice>/<prefix>-<name>.scope"]
    - ["/path/to/cg"] (legacy absolute) -> ["/sys/fs/cgroup/path/to/cg"]
    - anything else is treated as a relative path under the unified root. *)

val ensure : Fpath.t -> (unit, [> `Msg of string ]) result
(** [ensure cg] creates the cgroup directory if it doesn't already exist. *)

val add_pid : Fpath.t -> int -> (unit, [> `Msg of string ]) result
(** [add_pid cg pid] appends [pid] to [cg/cgroup.procs]. The kernel moves the
    process into the cgroup. *)

val remove : Fpath.t -> unit
(** [remove cg] best-effort [rmdir] the cgroup directory. The kernel only allows
    this once the cgroup has no processes. *)
