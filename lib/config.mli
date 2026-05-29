(** Parsing of the OCI runtime [config.json] bundle file.

    Only the subset of the OCI Runtime Specification that is meaningful for a
    Solo5 unikernel is decoded; unknown fields are ignored. Solo5 devices
    (memory, network, block) are configured through OCI [annotations] rather
    than dedicated fields - see {!Net} and {!Solo5} for the annotation scheme.
*)

type process = {
    args: string list  (** [argv]; the first element selects the unikernel. *)
  ; env: string list  (** Environment, [KEY=VALUE] entries. *)
  ; cwd: Fpath.t  (** Working directory (unused by Solo5, kept for fidelity). *)
  ; terminal: bool  (** Whether a terminal was requested (Solo5 has none). *)
}

type root = {
    path: Fpath.t  (** rootfs path, relative to the bundle or absolute. *)
  ; readonly: bool
}

(** OCI lifecycle hooks. Each hook receives the container {!State.t} as JSON on
    its standard input. *)
module Hooks : sig
  type entry = {
      path: Fpath.t  (** Executable to run. *)
    ; args: string list
    ; env: string list
    ; timeout: int option
  }

  type t = {
      prestart: entry list  (** Run by {!Runtime.create}. *)
    ; poststart: entry list  (** Run by {!Runtime.start}. *)
    ; poststop: entry list  (** Run by {!Runtime.delete}. *)
  }

  val empty : t
  val entry : entry Jsont.t
  val json : t Jsont.t
end

(** OCI Linux-specific block. Only the namespace list is decoded - used to
    detect when an orchestrator (Docker, containerd) provides a pre-built
    network namespace through [linux.namespaces[].path]. *)
module Linux : sig
  type namespace = {
      ns_type: string  (** ["network"], ["pid"], etc. *)
    ; path: Fpath.t option
          (** Bind-mount path (e.g. [/var/run/docker/netns/<id>] or
              [/proc/<pid>/ns/net]) when joining an existing ns. *)
  }

  type t = {
      namespaces: namespace list
    ; cgroups: string option
          (** OCI [linux.cgroupsPath]. Either an absolute path under
              [/sys/fs/cgroup] (legacy), or the systemd notation
              ["slice:prefix:name"] (e.g. ["system.slice:docker:<id>"]). The
              runtime is expected to create the cgroup and add the container's
              process to it. *)
  }
end

type t = {
    oci_version: string
  ; process: process
  ; root: root
  ; hostname: [ `host ] Domain_name.t option
  ; annotations: (string * string) list
  ; hooks: Hooks.t
  ; linux: Linux.t option
}

val netns : t -> Fpath.t option
(** [netns c] is the bind-mount path of the network namespace declared in
    [linux.namespaces], or [None] if absent or no path is given (in which case
    the runtime is expected to create a fresh netns). *)

val has_network_namespace : t -> bool
(** [has_network_namespace c] is [true] when [linux.namespaces] contains an
    entry of type ["network"], regardless of whether a [path] is set. In the
    no-path case the runtime is required to create the namespace itself; the
    orchestrator then bind-mounts [/proc/<state.pid>/ns/net]. *)

val cgroups : t -> string option
(** [cgroups c] is the OCI [linux.cgroupsPath], or [None] when no cgroup
    placement is requested. *)

val annotations : (string * string) list Jsont.t
(** {!Jsont.t} value for an annotation map. *)

val of_string : string -> (t, [> `Msg of string ]) result
(** [of_string s] decodes the contents of a [config.json] file. *)

val to_string : t -> (string, [> `Msg of string ]) result
(** [to_string v] encodes [v] as an [config.json] document. *)
