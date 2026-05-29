  $ chmod +x fixtures/solo5-hvt fixtures/solo5-elftool
  $ export SOLO5_HVT=fixtures/solo5-hvt SOLO5_ELFTOOL=fixtures/solo5-elftool
  $ export SOLO5_HVT_EXPECT='--ipv4=10.0.0.2/24
  > --name=web'
  $ a() { aussi --root . "$@"; }

  $ a create -b fixtures/bundle-argv a1
  $ a state a1
  {
    "ociVersion": "1.0.0",
    "id": "a1",
    "status": "created",
    "pid": 0,
    "bundle": "$TESTCASE_ROOT/fixtures/bundle-argv/",
    "annotations": {
      "solo5.app.ipv4": "10.0.0.2/24",
      "solo5.app.name": "web"
    }
  }

  $ a start a1
  $ a delete a1
  aussi: container a1 is still running, use --force
  [124]
  $ a delete a1 --force
  $ a state a1
  aussi: container a1 does not exist
  [124]
