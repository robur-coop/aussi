  $ chmod +x fixtures/solo5-hvt fixtures/solo5-elftool
  $ export SOLO5_HVT=fixtures/solo5-hvt SOLO5_ELFTOOL=fixtures/solo5-elftool
  $ export SOLO5_ELFTOOL_DEVICES='[{"name":"disk","type":"BLOCK_BASIC"}]'
  $ export SOLO5_HVT_EXPECT='--block:disk=/var/lib/aussi/disk.img
  > --block-sector-size:disk=4096'
  $ a() { aussi --root . "$@"; }

  $ a create -b fixtures/bundle-block b1
  $ a state b1
  {
    "ociVersion": "1.0.0",
    "id": "b1",
    "status": "created",
    "pid": 0,
    "bundle": "$TESTCASE_ROOT/fixtures/bundle-block/",
    "annotations": {
      "solo5.block.disk": "/var/lib/aussi/disk.img",
      "solo5.block.disk.sector-size": "4096"
    }
  }

  $ a start b1
  $ a delete b1
  aussi: container b1 is still running, use --force
  [124]
  $ a delete b1 --force
  $ a state b1
  aussi: container b1 does not exist
  [124]
