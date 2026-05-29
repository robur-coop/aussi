  $ chmod +x fixtures/solo5-hvt fixtures/solo5-elftool
  $ export SOLO5_HVT=fixtures/solo5-hvt SOLO5_ELFTOOL=fixtures/solo5-elftool
  $ a() { aussi --root . "$@"; }

  $ a create -b fixtures/bundle c1
  $ a state c1
  {
    "ociVersion": "1.0.0",
    "id": "c1",
    "status": "created",
    "pid": 0,
    "bundle": "$TESTCASE_ROOT/fixtures/bundle/",
    "annotations": {}
  }

  $ a create -b fixtures/bundle c1
  aussi: container c1 already exists
  [124]

  $ a start c1
  $ a delete c1
  aussi: container c1 is still running, use --force
  [124]
  $ a delete c1 --force
  $ a state c1
  aussi: container c1 does not exist
  [124]
  $ a list
  ID                                       STATUS     PID      BUNDLE
