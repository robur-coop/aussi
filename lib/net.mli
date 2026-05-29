(** Host-side network setup for Solo5 [net] devices.

    Each Solo5 network device is backed by a host TAP interface. The mapping is
    expressed through OCI annotations:

    - [solo5.net.<name>] [= "<tap>"]: TAP interface name (auto-generated as
      ["v<name>"] when absent);
    - [solo5.net.<name>.ip] [= "<cidr>"]: optional host-side address in CIDR
      notation;
    - [solo5.net.<name>.mac] [= "<mac>"]: optional guest MAC address;
    - [solo5.net.<name>.docker] [= "<iface>"]: when set, the device is bridged
      with the named interface ([eth0], [eth1], …) inside the orchestrator's
      netns instead of getting a standalone host TAP.

    TAP creation and addressing use [ip] on Linux and [ifconfig] on FreeBSD; the
    platform is detected at runtime. These operations require privileges
    (typically root or [CAP_NET_ADMIN]). *)

(** A Solo5 network device, either backed by a host-side TAP that [aussi]
    creates itself, or by a TAP wired into Docker's container netns. *)
type guest =
  | Tap of {
        name: string  (** Solo5 device name, e.g. ["service"]. *)
      ; tap: string  (** Host TAP interface name, e.g. ["tap100"]. *)
      ; cidr: Ipaddr.Prefix.t option  (** Host-side address. *)
      ; mac: Macaddr.t option  (** Guest MAC address. *)
    }
      (** Standalone host TAP. {!setup} creates/configures it on the host and
          {!teardown} destroys it. *)
  | Docker of {
        name: string  (** Solo5 device name. *)
      ; tap: string  (** TAP name created inside the Docker netns. *)
      ; mac: Macaddr.t option
            (** Guest MAC address, typically mirrored from the orchestrator's
                interface so the unikernel answers ARP with the MAC the bridge
                already saw. *)
      ; iface: string
            (** Name of the interface inside the container's netns to bridge
                with ([eth0], [eth1], ...). *)
    }
      (** Bridged with one of the orchestrator's interfaces inside the container
          netns ([solo5.net.<n>.docker = "<iface>"]); set up via
          {!bridge_with_iface} at start time, destroyed implicitly when the
          orchestrator tears down its netns. *)

val name : guest -> string
(** Solo5 device name. *)

val tap : guest -> string
(** TAP interface name. *)

val parse_interfaces : (string * string) list -> guest list
(** [parse_interfaces annotations] extracts the network interfaces described by
    the [solo5.net.*] annotations, sorted by device name. *)

val setup : ?netns:Fpath.t -> guest list -> (unit, [> `Msg of string ]) result
(** [setup ?netns ifaces] creates and configures the host-side TAP for every
    {!Tap} variant: assigns its CIDR and brings it up. {!Docker} variants are
    skipped: their tap is created later by {!bridge_with_iface} at start time,
    once the orchestrator has finished wiring the netns (libnetwork may rewrite
    [/proc/<pid>/ns/net] between create and start). When [netns] is given the
    taps live inside that namespace; without it they live on the host. Existing
    taps are reused. *)

val teardown : ?netns:Fpath.t -> guest list -> unit
(** [teardown ?netns_path ifaces] destroys the taps. Pass [None] when the netns
    is going away on its own (Docker tears down its sandbox and everything
    inside it). Errors are logged, not raised. *)

val to_hvt_args : guest list -> string list
(** [to_hvt_args ifaces] renders the [--net:] / [--net-mac:] arguments passed to
    [solo5-hvt]. *)

(** {2 Docker bridge integration}

    When [docker run --network=bridge] is used, Docker pre-builds a netns at
    [/var/run/docker/netns/<id>] with an [eth0] interface plumbed to [docker0]
    and an IP assigned by its IPAM. The functions below inspect and repurpose
    that netns to bridge the Solo5 TAP into the same L2 segment. *)

type host = {
    ifname: string  (** Netns-local interface name, e.g. ["eth0"]. *)
  ; cidr: Ipaddr.V4.Prefix.t option
        (** IPv4 with prefix in CIDR notation, e.g. ["172.17.0.2/16"]. *)
  ; cidr6: Ipaddr.V6.Prefix.t option
        (** IPv6 with prefix in CIDR notation, e.g. ["fd00::2/64"]. *)
  ; gateway: Ipaddr.V4.t option
        (** IPv4 default-route gateway on this interface, when there is one.
            IPv6 has no equivalent field: Docker leaves the IPv6 default route
            to come from router advertisements, so the unikernel learns it via
            its own stack rather than from an explicit annotation. *)
  ; mac: Macaddr.t  (** Interface MAC (mirrored onto the unikernel). *)
}

val inspect_docker_ifaces : Fpath.t -> (host list, [> `Msg of string ]) result
(** [inspect_docker_ifaces path] enumerates every non-loopback interface in the
    netns at [path], parsing [ip -j addr show] and [ip -j route show default].
    The result is sorted by interface name so multi-iface pairing in {!Runtime}
    is deterministic. *)

val bridge_with_iface :
     netns:Fpath.t
  -> tap:string
  -> bridge:string
  -> src:string
  -> (unit, [> `Msg of string ]) result
(** [bridge_with_iface ~netns_path ~tap ~bridge ~src_iface] wires an existing
    [tap] (created by {!setup}) with the netns-local interface [src_iface]
    through a new L2 [bridge]. Every address (IPv4 and IPv6) on [src_iface] is
    flushed so only the unikernel (which takes them via its argv) answers
    ARP/ND. *)
