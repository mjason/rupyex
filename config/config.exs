import Config

# Only applies when this repository is the project being built: dependencies do
# not read it. Locally we always compile the crate; CI sets RUPYEX_PRECOMPILED=1
# when it wants the published artifacts instead (to generate the checksum file).
config :rustler_precompiled, :force_build, rupyex: System.get_env("RUPYEX_PRECOMPILED") != "1"
