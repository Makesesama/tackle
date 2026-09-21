import Config

# Tests drive the TUI through `test_mode`, so there is no interactive terminal
# to hand off to crossterm's reader. Once a local-transport app has run in the
# suite the BEAM's `:user_drv_reader` exists but cannot ack the handoff, and
# every later TUI start would wait out the handoff's 1s ack timeout.
config :ex_ratatui, detach_local_input: false
