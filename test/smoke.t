  $ aussi spec
  {
    "ociVersion": "1.0.0",
    "process": {
      "args": [
        "unikernel.hvt"
      ],
      "env": [],
      "cwd": "/",
      "terminal": false
    },
    "root": {
      "path": "rootfs",
      "readonly": true
    },
    "hostname": "solo5",
    "annotations": {
      "solo5.mem": "512",
      "solo5.net.service": "tap100",
      "solo5.net.service.ip": "10.0.0.1/24"
    },
    "hooks": {
      "prestart": [],
      "poststart": [],
      "poststop": []
    }
  }

  $ aussi features
  {
    "ociVersionMin": "1.0.0",
    "ociVersionMax": "1.2.0",
    "hooks": [
      "prestart",
      "poststart",
      "poststop"
    ],
    "mountOptions": [],
    "annotations": {
      "solo5.block.<name>": "Host path of the file backing a Solo5 block device",
      "solo5.block.<name>.sector-size": "Sector size in bytes for the block device",
      "solo5.cmdline": "Whitespace-separated unikernel argv template (annotations expanded)",
      "solo5.mem": "Guest memory in MB",
      "solo5.net.<name>": "Host tap interface backing a Solo5 net device",
      "solo5.net.<name>.docker": "Interface name inside the container netns to bridge with (eth0, eth1, ...)",
      "solo5.net.<name>.gw": "IPv4 default gateway",
      "solo5.net.<name>.ip": "IPv4 address in CIDR notation",
      "solo5.net.<name>.ipv6": "IPv6 address in CIDR notation",
      "solo5.net.<name>.mac": "Guest MAC address"
    }
  }

  $ aussi --root . list
  ID                                       STATUS     PID      BUNDLE

  $ aussi --root . state nope
  aussi: container nope does not exist
  [124]
