# Aussi, an OCI-compatible container runtime for [Solo5][solo5]

`aussi` is a program which allows you to run Solo5 `hvt` unikernels through
standard container tooling (Docker, containerd, Podman) instead of managing
`solo5-hvt` by hand. If someone wishes to deploy Solo5 unikernels, it is
advisable to opt for [Albatross][albatross], which has been designed
specifically for deploying unikernels. Aussi's main purpose is to capitalise on
the benefits of [IPAM][IPAM] and enable new users to test unikernels with
relative simplicity. In a real-world deployment scenario, we prefer IP address
allocation to be managed by our own unikernel: [dnsvizor][dnsvizor].

## Give a try!

First, we will install `aussi`, as well as a unikernel, to demonstrate how to
deploy it: [`annuaire`][annuaire] and, specifically, `pagejaune`, a recursive
DNS resolver.
```bash
$ opam pin add https://github.com/robur-coop/aussi
$ opam pin add https://github.com/dinosaure/annuaire
$ file $(opam var bin)/pagejaune.hvt
/home/.../.opam/5.4.0/bin/pagejaune.hvt: ELF 64-bit LSB executable,
  x86-64, version 1 (SYSV), statically linked,
  interpreter /nonexistent/solo5/, for OpenBSD, stripped
```

Next, we’ll need to create a bundle folder to contain the unikernel and its
configuration.
```bash
$ mkdir bundle
$ mkdir bundle/rootfs
$ cp $(opam var bin)/pagejaune.hvt bundle/rootfs/
$ cat >bundle/rootfs/solo5.json<<EOF
{
  "version": 1,
  "type": "solo5.config",
  "mem": 32,
  "nets": { "service": { "type": "tap", "tap": "tap0", "cidr": "10.0.0.2/24" } },
  "argv": [
    "--ipv4=%{solo5.net.service.ip}",
    "--ipv4-gateway=%{solo5.net.service.gw}",
    "--domain", "foo.local",
    "--dnssec", "--qname-minimisation",
    "--tls-lifetime", "1h", "--seed", "foo="
  ]
}
EOF
$ cat >bundle/config.json<<EOF
{
  "ociVersion": "1.0.0",
  "root": { "path": "rootfs" },
  "process": { "args": ["pagejaune.hvt"] },
  "annotations": {
    "solo5.net.service": "tap0",
    "solo5.net.service.ip": "10.0.0.2/24",
    "solo5.net.service.gw": "10.0.0.1"
  }
}
EOF
```

The `solo5.json` file specifies how the unikernel should be launched, and the
`config.json` file is the OCI configuration file that other orchestrators can
interpret (like Docker).

You can therefore create a new container in this way as:
```bash
$ sudo aussi create --bundle bundle pagejaune
$ sudo aussi list
ID                                       STATUS     PID      BUNDLE
pagejaune                                created    -        /home/.../bundle/
```

Next, we will take on the role of the IPAM and configure the network for our
unikernel. This involves creating a bridge and allowing packets to be forwarded
from a local IP address to a public IP address (we assume that your internet
connection is via `wlan0`):
```bash
$ sudo sysctl -w net.ipv4.ip_forward=1
$ sudo ip link add name service type bridge
$ sudo ip addr add 10.0.0.1/24 dev service
$ sudo ip link set tap0 master service
$ sudo ip link set service up
$ sudo iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o wlan0 -j MASQUERADE
$ sudo iptables -A FORWARD -i service -o wlan0 -j ACCEPT
$ sudo iptables -A FORWARD -i wlan0 -o service -m state --state RELATED,ESTABLISHED -j ACCEPT
```

We can now launch our unikernel and test it!
```bash
$ sudo aussi start pagejaune
$ dig google.com @10.0.0.2 +short
142.251.39.206
```

We can now stop our container and delete it.
```bash
$ sudo aussi kill pagejaune
$ sudo aussi delete pagejaune
```

This is a fairly basic example, but it demonstrates `aussi`'s ability to
allocate resources such as the tap interface required by the unikernel. Of
course, all the underlying infrastructure for the bridge is also required, but
this can be handled by Docker, so we'll now look at how to run this same
unikernel using a Dockerfile.

## With Docker!

First, we need to tell Docker that there is a new runtime for our unikernels:
```bash
# cat >/etc/docker/daemon.json<<EOF
{
  "runtimes": {
    "solo5": {
      "path": "/home/.../.opam/5.4.0/bin/aussi",
      "runtimeArgs": ["--log", "/tmp/aussi.log", "--log-format", "json"]
    }
  }
}
# systemctl restart docker
```

Next, using multi-stage, we can compile and prepare our unikernel:
```bash
$ cat >solo5.json <<EOF
{
  "version": 1,
  "type": "solo5.config",
  "mem": 32,
  "nets": {
    "service": { "type": "docker", "iface": "eth0" }
  },
  "argv": [
    "--ipv4=%{solo5.net.service.ip}",
    "--ipv4-gateway=%{solo5.net.service.gw}",
    "--color=always",
    "--domain", "foo.local",
    "--dnssec", "--qname-minimisation",
    "--tls-lifetime", "1h",
    "--seed", "foo="
  ]
}
EOF
$ cat >Dockerfile<<EOF
FROM ocaml/opam:debian-12-ocaml-5.4 AS builder
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
  pkg-config m4 build-essential libgmp-dev libseccomp-dev && \
  rm -rf /var/lib/apt/lists/*
USER opam
RUN opam init --reinit --bare --disable-sandboxing -y
WORKDIR /home/opam
RUN opam update && opam install -y solo5 ocaml-solo5
RUN git clone https://github.com/dinosaure/annuaire annuaire
RUN cd annuaire
WORKDIR /home/opam/annuaire
RUN opam pin add -yn annuaire .
RUN opam install annuaire --deps-only
RUN opam exec -- make all

FROM scratch
COPY --from=builder /home/opam/annuaire/pagejaune.hvt /pagejaune.hvt
COPY solo5.json /solo5.json
ENTRYPOINT ["/pagejaune.hvt"]
EOF
$ docker build -t pagejaune .
```

You can now run the unikernel with Docker! To demonstrate the full power of
Docker, we’re going to forward port 1153 to port 53 on our unikernel.

```bash
$ docker run -d --runtime=solo5 -p 1153:53/udp pagejaune
794088ff33a468f44c420bd08f5160332d46684d993212e7f7add59edcf4f6ad
$ dig -p 1153 @localhost google.com +short
142.251.39.206
```

[solo5]: https://github.com/solo5/solo5
[albatross]: https://github.com/robur-coop/albatross
[IPAM]: https://en.wikipedia.org/wiki/IP_address_management
[dnsvizor]: https://github.com/robur-coop/dnsvizor
[annuaire]: https://github.com/dinosaure/annuaire
