#!/usr/bin/env bats
# Tests for the Linux (kernel keyring) credential backend — _kc_* functions
# and the `_container-init` bootstrap subcommand claudebox calls inside a
# container. Uses a mocked `uname -s` -> "Linux" and a mocked `keyctl`.

load 'helpers/common'

setup()    { setup_flux_test_linux; }
teardown() { teardown_flux_test; }

@test "_container-init requires bucket, access key, and secret key" {
  run bash "$REPO_ROOT/flux" _container-init
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: flux _container-init"* ]]

  run bash "$REPO_ROOT/flux" _container-init test-bucket
  [ "$status" -ne 0 ]

  run bash "$REPO_ROOT/flux" _container-init test-bucket only-ak
  [ "$status" -ne 0 ]
}

@test "_container-init seeds the keyring so _credential-helper can read it back" {
  run bash "$REPO_ROOT/flux" _container-init test-bucket my-access-key my-secret-key
  [ "$status" -eq 0 ]

  git config flux.dvc-remote-bucket test-bucket

  run bash "$REPO_ROOT/flux" _credential-helper
  [ "$status" -eq 0 ]
  [[ "$output" == *'"AccessKeyId":"my-access-key"'* ]]
  [[ "$output" == *'"SecretAccessKey":"my-secret-key"'* ]]
}

@test "_container-init overwrites previously seeded credentials for the same bucket" {
  bash "$REPO_ROOT/flux" _container-init test-bucket old-ak old-sk
  run bash "$REPO_ROOT/flux" _container-init test-bucket new-ak new-sk
  [ "$status" -eq 0 ]

  git config flux.dvc-remote-bucket test-bucket

  run bash "$REPO_ROOT/flux" _credential-helper
  [ "$status" -eq 0 ]
  [[ "$output" == *'"AccessKeyId":"new-ak"'* ]]
  [[ "$output" == *'"SecretAccessKey":"new-sk"'* ]]
}

@test "_container-init keeps credentials for different buckets separate" {
  bash "$REPO_ROOT/flux" _container-init bucket-a ak-a sk-a
  bash "$REPO_ROOT/flux" _container-init bucket-b ak-b sk-b

  git config flux.dvc-remote-bucket bucket-a
  run bash "$REPO_ROOT/flux" _credential-helper
  [[ "$output" == *'"AccessKeyId":"ak-a"'* ]]

  git config flux.dvc-remote-bucket bucket-b
  run bash "$REPO_ROOT/flux" _credential-helper
  [[ "$output" == *'"AccessKeyId":"ak-b"'* ]]
}

@test "_credential-helper fails with no credentials seeded on Linux" {
  git config flux.dvc-remote-bucket test-bucket
  run bash "$REPO_ROOT/flux" _credential-helper
  [ "$status" -ne 0 ]
  [[ "$output" == *"no credentials for bucket"* ]]
}

@test "_container-init writes the flux-dvc AWS credential_process profile" {
  bash "$REPO_ROOT/flux" _container-init test-bucket my-access-key my-secret-key
  run cat "$MOCK_HOME/.aws/config"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[profile flux-dvc]"* ]]
  [[ "$output" == *"_credential-helper"* ]]
}
