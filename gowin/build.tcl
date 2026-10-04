# Gowin batch build. Run from gowin/ via:  python tools/run.py synth   (calls: gw_sh build.tcl)
#
# The design is described once, by the Gowin project in this folder:
#   gowin/gqh.gprj                        device, source files (package first), organizer .cst, gqh.sdc
#   gowin/impl/gqh_process_config.json    options: top module `top`, SystemVerilog 2017, output base name gqh
# This script builds that project, so the batch build and "open gowin/gqh.gprj in the IDE, Run All" are
# the same build. Outputs land in gowin/impl/ (gwsynthesis/, pnr/gqh.fs).
# Checked against gw_sh V1.9.11.03 Education: open_project + run all gives the same resource usage and
# the same bitstream content as the previous add_file script.
#
# A new file in src/ must be added to gqh.gprj (IDE: Add Files, or edit the FileList by hand, with
# paths relative to gowin/, i.e. ../src/<file>). tools/run.py synth refuses to build if the two disagree.

open_project gqh.gprj
run all
