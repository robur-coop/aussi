(** Optional [solo5.json] file shipped inside the rootfs, providing default
    Solo5 device configuration.

    Values from [solo5.json] are turned into OCI annotations and act as
    {e defaults}: any annotation set on the OCI [config.json] overrides the
    corresponding [solo5.json] entry (see {!merge_annotations}). This lets a
    unikernel image carry sensible defaults while staying overridable by the
    orchestrator. *)

(** Version 1 of the [solo5.json] schema. *)
module V1 : sig
  type t

  val argv : t -> string list
  (** [argv cfg] is the templated unikernel argv declared by the image author
      (the [argv] array of [solo5.json]). Each token may contain
      [%{annotation.key}] placeholders, resolved by the runtime against the
      merged annotations. *)

  val to_annotations : t -> (string * string) list
  (** [to_annotations cfg] flattens the configuration into [solo5.*] annotations
      (["solo5.mem"], ["solo5.net.<name>"], ["solo5.net.<name>.ip"],
      ["solo5.net.<name>.mac"], ["solo5.block.<name>"]). *)
end

(** A versioned [solo5.json] document. *)
type t = V1 of V1.t

val load : Fpath.t -> t option
(** [load rootfs] reads and decodes [rootfs/solo5.json] if present and valid,
    [None] otherwise. *)

val merge_annotations :
     defaults:(string * string) list
  -> overrides:(string * string) list
  -> (string * string) list
(** [merge_annotations ~defaults ~overrides] returns the union of both lists,
    sorted by key, with [overrides] winning on conflicting keys. *)
