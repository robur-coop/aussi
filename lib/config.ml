type process = {
    args: string list
  ; env: string list
  ; cwd: Fpath.t
  ; terminal: bool
}

type root = { path: Fpath.t; readonly: bool }

let filepath =
  let enc = Fpath.to_string and dec = Fpath.v in
  Jsont.map ~enc ~dec Jsont.string

let dirpath =
  let enc = Fpath.to_string and dec = Fun.compose Fpath.to_dir_path Fpath.v in
  Jsont.map ~enc ~dec Jsont.string

module Hooks = struct
  type entry = {
      path: Fpath.t
    ; args: string list
    ; env: string list
    ; timeout: int option
  }

  type t = { prestart: entry list; poststart: entry list; poststop: entry list }

  let entry =
    Jsont.Object.map ~kind:"hook" (fun path args env timeout ->
        { path; args; env; timeout })
    |> Jsont.Object.mem "path" filepath ~enc:(fun h -> h.path)
    |> Jsont.Object.mem "args"
         Jsont.(list string)
         ~enc:(fun h -> h.args)
         ~dec_absent:[]
    |> Jsont.Object.mem "env"
         Jsont.(list string)
         ~enc:(fun h -> h.env)
         ~dec_absent:[]
    |> Jsont.Object.opt_mem "timeout" Jsont.int ~enc:(fun h -> h.timeout)
    |> Jsont.Object.finish

  let empty = { prestart= []; poststart= []; poststop= [] }

  let json =
    Jsont.Object.map ~kind:"hooks" (fun prestart poststart poststop ->
        { prestart; poststart; poststop })
    |> Jsont.Object.mem "prestart"
         Jsont.(list entry)
         ~enc:(fun h -> h.prestart)
         ~dec_absent:[]
    |> Jsont.Object.mem "poststart"
         Jsont.(list entry)
         ~enc:(fun h -> h.poststart)
         ~dec_absent:[]
    |> Jsont.Object.mem "poststop"
         Jsont.(list entry)
         ~enc:(fun h -> h.poststop)
         ~dec_absent:[]
    |> Jsont.Object.finish
end

module Linux = struct
  type namespace = { ns_type: string; path: Fpath.t option }
  type t = { namespaces: namespace list; cgroups: string option }

  let namespace =
    Jsont.Object.map ~kind:"namespace" (fun ns_type path -> { ns_type; path })
    |> Jsont.Object.mem "type" Jsont.string ~enc:(fun n -> n.ns_type)
    |> Jsont.Object.opt_mem "path" filepath ~enc:(fun n -> n.path)
    |> Jsont.Object.finish

  let json =
    Jsont.Object.map ~kind:"linux" (fun namespaces cgroups ->
        { namespaces; cgroups })
    |> Jsont.Object.mem "namespaces"
         Jsont.(list namespace)
         ~enc:(fun l -> l.namespaces)
         ~dec_absent:[]
    |> Jsont.Object.opt_mem "cgroupsPath" Jsont.string ~enc:(fun l -> l.cgroups)
    |> Jsont.Object.finish
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

let netns c =
  match c.linux with
  | None -> None
  | Some lx ->
      List.find_map
        (fun (n : Linux.namespace) ->
          if n.ns_type = "network" then n.path else None)
        lx.namespaces

let has_network_namespace c =
  match c.linux with
  | None -> false
  | Some lx ->
      List.exists
        (fun (n : Linux.namespace) -> n.ns_type = "network")
        lx.namespaces

let cgroups c = match c.linux with None -> None | Some lx -> lx.cgroups
let ( let* ) = Result.bind

let domain_name =
  let dec str =
    let* dn = Domain_name.of_string str in
    Domain_name.host dn
  in
  let dec str =
    match dec str with
    | Ok value -> value
    | Error (`Msg msg) -> Fmt.failwith "Invalid domain-name %S: %s" str msg
  in
  let enc = Domain_name.to_string in
  Jsont.map ~enc ~dec Jsont.string

let process =
  Jsont.Object.map ~kind:"process" (fun args env cwd terminal ->
      { args; env; cwd; terminal })
  |> Jsont.Object.mem "args"
       Jsont.(list string)
       ~enc:(fun p -> p.args)
       ~dec_absent:[]
  |> Jsont.Object.mem "env"
       Jsont.(list string)
       ~enc:(fun p -> p.env)
       ~dec_absent:[]
  |> Jsont.Object.mem "cwd" dirpath
       ~enc:(fun p -> p.cwd)
       ~dec_absent:(Fpath.v "/")
  |> Jsont.Object.mem "terminal" Jsont.bool
       ~enc:(fun p -> p.terminal)
       ~dec_absent:false
  |> Jsont.Object.finish

let root =
  Jsont.Object.map ~kind:"root" (fun path readonly -> { path; readonly })
  |> Jsont.Object.mem "path" dirpath ~enc:(fun r -> r.path)
  |> Jsont.Object.mem "readonly" Jsont.bool
       ~enc:(fun r -> r.readonly)
       ~dec_absent:false
  |> Jsont.Object.finish

module S = Map.Make (String)

let annotations =
  let open Jsont in
  let m =
    Object.map ~kind:"annotations" Fun.id
    |> Object.keep_unknown (Object.Mems.string_map Jsont.string) ~enc:Fun.id
    |> Object.finish
  in
  let dec m = S.bindings m in
  let enc l = List.fold_left (fun m (k, v) -> S.add k v m) S.empty l in
  map ~dec ~enc m

let t =
  let open Jsont in
  Object.map ~kind:"oci-config"
    (fun oci_version process root hostname annotations hooks linux ->
      { oci_version; process; root; hostname; annotations; hooks; linux })
  |> Object.mem "ociVersion" Jsont.string ~enc:(fun c -> c.oci_version)
  |> Object.mem "process" process
       ~enc:(fun c -> c.process)
       ~dec_absent:{ args= []; env= []; cwd= Fpath.v "/"; terminal= false }
  |> Object.mem "root" root
       ~enc:(fun c -> c.root)
       ~dec_absent:{ path= Fpath.v "rootfs"; readonly= false }
  |> Object.opt_mem ~enc:(fun c -> c.hostname) "hostname" domain_name
  |> Object.mem "annotations" annotations
       ~enc:(fun c -> c.annotations)
       ~dec_absent:[]
  |> Object.mem "hooks" Hooks.json
       ~enc:(fun c -> c.hooks)
       ~dec_absent:Hooks.empty
  |> Object.opt_mem "linux" Linux.json ~enc:(fun c -> c.linux)
  |> Object.finish

let of_string str =
  match Jsont_bytesrw.decode_string t str with
  | Ok _ as value -> value
  | Error msg -> Error (`Msg msg)

let to_string v =
  match Jsont_bytesrw.encode_string ~format:Jsont.Indent t v with
  | Ok _ as value -> value
  | Error msg -> Error (`Msg msg)
