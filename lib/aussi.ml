(** OCI runtime for Solo5 unikernels.

    {!Runtime} implements the OCI verbs (create/start/state/kill/delete/...),
    {!Config} decodes the bundle's [config.json] and {!State} the persisted
    container state. *)

module Config = Config
module State = State
module Runtime = Runtime
