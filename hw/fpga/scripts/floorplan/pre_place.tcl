# Floorplan, before placement: scalar unit, DMA and vector issue in SLR0, the lanes in SLR1, the matrix units in
# SLR2, the XLU in SLR ::tpu_xlu_slr. Only the large blocks are anchored.
# Options ::tpu_xlu_slr, ::tpu_uram_read_columns, ::tpu_dsp_bands: the image's [floorplan] table, which build.py
# turns into "set ::tpu_<key> <value>" lines before sourcing this script.
set_msg_config -id {Vivado 12-3520} -suppress
set core [get_cells -hier -filter {REF_NAME == tpu || ORIG_REF_NAME == tpu}]
if {[llength $core] != 1} {error "Expected one TPU core"}
set core_name [get_property NAME $core]
set prefix "$core_name/"

set lane_count [llength [get_cells -hier -filter {REF_NAME == vlane || REF_NAME =~ vlane_* || ORIG_REF_NAME == vlane}]]
foreach module {vlane vector_dma_channel} {
    set instances [get_cells -hier -filter "REF_NAME == $module || REF_NAME =~ ${module}_* || ORIG_REF_NAME == $module"]
    if {[llength $instances] != $lane_count} {error "Expected $lane_count $module instances"}
    foreach instance $instances {
        if {![string is true -strict [get_property KEEP_HIERARCHY $instance]]} {
            error "$instance lacks KEEP_HIERARCHY: synthesize with boundaries.xdc"
        }
    }
}

# v++ assigns the whole kernel to SLR0: clear it from the core up to tpu_kernel.
set ancestors {}
set kernel_top -1
for {set name $core_name} {$name ne "." && $name ne ""} {set name [file dirname $name]} {
    set cell [get_cells -quiet $name]
    if {![llength $cell]} {continue}
    lappend ancestors $cell
    if {[string match -nocase *tpu_kernel* "[get_property -quiet REF_NAME $cell] [get_property -quiet ORIG_REF_NAME $cell]"]} {
        set kernel_top [expr {[llength $ancestors] - 1}]
    }
}
foreach cell [lrange $ancestors 0 $kernel_top] {
    if {[get_property -quiet USER_SLR_ASSIGNMENT $cell] ne ""} {reset_property USER_SLR_ASSIGNMENT $cell}
}

foreach slr {0 1 2} {
    set block [get_pblocks -quiet pblock_dynamic_SLR$slr]
    if {![llength $block]} {
        set block [create_pblock pblock_dynamic_SLR$slr]
        resize_pblock $block -add SLR$slr
        set_property CONTAIN_ROUTING false $block
        set_property EXCLUDE_PLACEMENT false $block
    }
    set_property IS_SOFT false $block
    set cells($slr) {}
}

set lanes [lrepeat $lane_count 0]
set engines [dict create]
set counts [dict create]
set primitives [get_cells -hier -filter {IS_PRIMITIVE}]
foreach cell $primitives full [get_property NAME $primitives] ref [get_property REF_NAME $primitives] {
    if {$ref in {GND VCC} || [string first $prefix $full] != 0} {continue}
    set name [string range $full [string length $prefix] end]
    set slr {}
    if {[regexp {^u_vector/gen_lane\[([0-9]+)\]\.} $name -> lane]} {
        set slr 1; set group lane
        lset lanes $lane [expr {[lindex $lanes $lane] + 1}]
    } elseif {[regexp {^u_vector/.*command(_valid)?_reg\[([0-9]+)\]} $name -> kind stage]} {
        set slr [expr {$stage > 0 || [string match FD* $ref]}]
        set group command_slr$slr
    } elseif {[regexp {^u_vector/u_issue/u_return/.*regs_reg\[([0-9]+)\]} $name -> stage] && [string match FD* $ref]} {
        set slr [expr {$stage == 0}]
        set group slot_return_slr$slr
    } elseif {[string first u_vector/u_issue/ $name] == 0} {
        set slr 0; set group admission
    } elseif {[regexp {^u_vector/gen_matmul_command\[|^u_vector/matmul_cmd_} $name]} {
        set slr 1; set group matmul_command
    } elseif {[regexp {^gen_feed\[[0-9]+\]\.gen_crossing\.gen_stage\[0\]\.u_stage/} $name]} {
        set slr 1; set group mxu_crossing_slr1
    } elseif {[regexp {^gen_feed\[[0-9]+\]\.(gen_crossing\.gen_stage\[1\]\.u_stage|u_feed)/} $name]} {
        set slr 2; set group mxu_feed
    } elseif {[regexp {^gen_mxu\[[0-9]+\]\.gen_enabled\.gen_lane\[[0-9]+\]\.gen_crossing\.u_result_rx/} $name]} {
        set slr 1; set group mxu_crossing_slr1
    } elseif {[regexp {^gen_mxu\[[0-9]+\]\.gen_enabled\.gen_command_crossing\.(u_tx|u_freed_rx)/} $name]} {
        set slr 1; set group mxu_crossing_slr1
    } elseif {[regexp {^gen_mxu\[[0-9]+\]\.gen_enabled\.gen_lane\[[0-9]+\]\.gen_crossing\.u_result_tx/} $name]} {
        set slr 2; set group mxu_crossing_mxu
    } elseif {[regexp {^gen_mxu\[[0-9]+\]\.gen_enabled\.gen_command_crossing\.(u_rx|u_freed_tx)/} $name]} {
        set slr 2; set group mxu_crossing_mxu
    } elseif {[regexp {^gen_mxu\[([0-9]+)\]\.} $name -> engine]} {
        set slr 2; set group mxu
        dict set engines $engine 1
    } elseif {[string first gen_transpose.u_transpose/ $name] == 0} {
        set slr $::tpu_xlu_slr; set group xlu
    } elseif {[string first gen_transpose $name] == 0} {
        set slr 1; set group xlu_io
    } elseif {[regexp {^u_vector/gen_channel\[[0-9]+\]\.u_dma/(u_request/|request_q_reg)} $name]} {
        set slr 1; set group dma_request
    } elseif {[regexp {^u_vector/gen_channel\[[0-9]+\]\.u_dma/(u_response/|u_arrival/|accepted_q|upper_q|second_q)} $name]} {
        set slr 0; set group dma_response
    } elseif {[string first u_dma/ $name] == 0} {
        set slr 0; set group dma
    } elseif {[string first u_scalar/ $name] == 0} {
        set slr 0; set group scalar
    } else {
        set group free
    }
    if {$slr ne ""} {lappend cells($slr) $cell}
    dict incr counts "$group/SLR[expr {$slr eq {} ? {free} : $slr}]"
}
if {0 in $lanes} {error "Missing vector lanes: $lanes"}
foreach group {command_slr1 slot_return_slr0 slot_return_slr1 admission xlu dma_request dma_response dma scalar} {
    if {![llength [dict filter $counts key $group/*]]} {error "Empty anchor group $group: $counts"}
}
foreach slr {0 1 2} {
    if {![llength $cells($slr)]} {continue}
    add_cells_to_pblock [get_pblocks pblock_dynamic_SLR$slr] $cells($slr)
    puts "TPU_ANCHOR SLR$slr anchored_primitives=[llength $cells($slr)]"
}
puts "TPU_ANCHOR groups=$counts lanes=$lanes MXUs=[dict size $engines]"

# DSP bands: two groups of 32-DSP cascade chains, each group in its half of SLR2's 30 DSP columns, cut into three
# 32-row bands so that a column holds 3 chains (the placer does not align them on its own).
# Each MXU is one group and each column of its pe_array (one DSP per row) is one chain.
if {$::tpu_dsp_bands} {
    proc dsp_chain {name} {
        if {![regexp {gen_mxu\[(\d)\].*gen_pe_col\[(\d+)\]} $name -> group chain]} {error "Unexpected MXU DSP $name"}
        return [list $group $chain]
    }
    set groups [dict create]
    foreach e {0 1} {foreach band {0 1 2} {set band_dsps($e,$band) {}}}
    set dsps [get_cells -hier -filter {REF_NAME == DSP48E2 && NAME =~ *gen_mxu*}]
    foreach dsp $dsps name [get_property NAME $dsps] {
        set key [dsp_chain $name]
        if {![llength $key]} {continue}
        lassign $key group chain
        dict set groups $group 1
        lappend band_dsps($group,[expr {$chain / 11}]) $dsp
    }
    if {[dict size $groups] == 2} {
        foreach e {0 1} {
            foreach band {0 1 2} {
                set y0 [expr {186 + 32 * $band}]
                set range "DSP48E2_X[expr {15 * $e}]Y$y0:DSP48E2_X[expr {15 * $e + 14}]Y[expr {$y0 + 31}]"
                set block [create_pblock pblock_mxu${e}_band$band]
                resize_pblock $block -add $range
                set_property PARENT [get_pblocks pblock_dynamic_SLR2] $block
                add_cells_to_pblock $block $band_dsps($e,$band)
                puts "TPU_ANCHOR MXU$e band$band $range DSPs=[llength $band_dsps($e,$band)]"
            }
        }
    }
}

set hook_dir [file dirname [info script]]
source [file join $hook_dir host_path.tcl]
source [file join $hook_dir lane_grid.tcl]
