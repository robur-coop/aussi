(** The Solo5 application manifest embedded in a [.hvt] binary.

    The manifest enumerates the devices ([NET_BASIC], [BLOCK_BASIC]) the
    unikernel expects. It is extracted with [solo5-elftool query-manifest]
    (overridable via the [SOLO5_ELFTOOL] environment variable) and checked
    against the configured annotations so that a mismatch is reported before the
    unikernel is started. *)

type t

val query : Fpath.t -> (t, [> `Msg of string ]) result
(** [query binary] runs [solo5-elftool query-manifest] on [binary] and decodes
    the resulting manifest. *)

val validate : t -> (string * string) list -> (unit, [> `Msg of string ]) result
(** [validate manifest annotations] succeeds iff every device declared in
    [manifest] has a matching [solo5.net.*] / [solo5.block.*] annotation and no
    such annotation refers to an undeclared device. The error message lists
    every missing and unexpected device. *)

val pp_devices : Format.formatter -> t -> unit
(** [pp_devices ppf m] prints the manifest's devices, one per line. *)
