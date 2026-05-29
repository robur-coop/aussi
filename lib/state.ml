type status = Creating | Created | Running | Stopped

let status =
  Jsont.enum
    [
      ("creating", Creating); ("created", Created); ("running", Running)
    ; ("stopped", Stopped)
    ]

type t = {
    oci_version: string
  ; id: string
  ; status: status
  ; pid: int
  ; bundle: Fpath.t
  ; annotations: (string * string) list
  ; exit_code: int option
  ; netns: Fpath.t option
}

let filepath =
  let enc = Fpath.to_string and dec = Fpath.v in
  Jsont.map ~enc ~dec Jsont.string

let json =
  Jsont.Object.map ~kind:"oci-state"
    (fun oci_version id status pid bundle annotations exit_code netns ->
      { oci_version; id; status; pid; bundle; annotations; exit_code; netns })
  |> Jsont.Object.mem "ociVersion" Jsont.string ~enc:(fun s -> s.oci_version)
  |> Jsont.Object.mem "id" Jsont.string ~enc:(fun s -> s.id)
  |> Jsont.Object.mem "status" status ~enc:(fun s -> s.status)
  |> Jsont.Object.mem "pid" Jsont.int ~enc:(fun s -> s.pid)
  |> Jsont.Object.mem "bundle" filepath ~enc:(fun s -> s.bundle)
  |> Jsont.Object.mem "annotations" Config.annotations
       ~enc:(fun s -> s.annotations)
       ~dec_absent:[]
  |> Jsont.Object.opt_mem "exitCode" Jsont.int ~enc:(fun s -> s.exit_code)
  |> Jsont.Object.opt_mem "netnsPath" filepath ~enc:(fun s -> s.netns)
  |> Jsont.Object.finish

let to_string state =
  match Jsont_bytesrw.encode_string ~format:Jsont.Indent json state with
  | Ok _ as v -> v
  | Error msg -> Error (`Msg msg)

let of_string str =
  match Jsont_bytesrw.decode_string json str with
  | Ok _ as v -> v
  | Error msg -> Error (`Msg msg)
