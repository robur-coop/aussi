  $ chmod +x fixtures/solo5-hvt fixtures/solo5-elftool
  $ export SOLO5_HVT=fixtures/solo5-hvt SOLO5_ELFTOOL=fixtures/solo5-elftool
  $ a() { aussi --root . "$@"; }

  $ a state ghost
  aussi: container ghost does not exist
  [124]
  $ a start ghost
  aussi: Container ghost does not exist
  [124]
  $ a kill ghost
  aussi: container ghost does not exist
  [124]
  $ a delete ghost
  aussi: container ghost does not exist
  [124]

  $ a create -b fixtures/bundle-empty e1
  aussi: $TESTCASE_ROOT/fixtures/bundle-empty/config.json:
         No such file
  [124]

  $ a create -b fixtures/bundle-nohvt e2
  aussi: No .hvt unikernel found in rootfs
  [124]

  $ SOLO5_ELFTOOL_DEVICES='[{"name":"service","type":"NET_BASIC"}]' a create -b fixtures/bundle e3
  aussi: The unikernel requires the following devices that are not configured:
         - service (NET_BASIC) add the appropriate solo5.net.<name> or
         solo5.block.<name> annotations
  [124]

  $ a run -b fixtures/bundle r1
  $ a delete r1 --force
  $ a list
  ID                                       STATUS     PID      BUNDLE
