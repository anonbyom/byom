# Each lane's VMEM is 8 URAMs (4 cascades of 2). SLR1 has 5 URAM columns, each 64 URAMs tall.
# Lanes are distributed among the 5 columns in snake order so that neighbouring lanes stay close.
# With ::tpu_uram_read_columns N > 0, its URAM read registers stay within N columns of its URAMs.
set uram_columns 5
set uram_y0 64
set uram_rows 64
set parent [get_pblocks pblock_dynamic_SLR1]

set lane_urams [dict create]
set urams [get_cells -of $parent -filter {IS_PRIMITIVE && REF_NAME == URAM288}]
foreach cell $urams name [get_property NAME $urams] {
    if {[regexp {/u_vector/gen_lane\[([0-9]+)\]\.} $name -> lane]} {dict lappend lane_urams $lane $cell}
}
if {[dict size $lane_urams] != $lane_count} {error "Expected $lane_count lanes with URAMs in SLR1, got [dict size $lane_urams]"}
set per_lane [llength [dict get $lane_urams 0]]
dict for {lane lane_cells} $lane_urams {
    if {[llength $lane_cells] != $per_lane} {error "Lane $lane has [llength $lane_cells] URAM288, lane 0 has $per_lane"}
}

proc read_ranges {x y rows columns} {
    set y0 [expr {int(floor(3.75 * $y))}]
    set y1 [expr {int(ceil(3.75 * ($y + $rows))) - 1}]
    set column [get_property COLUMN [get_tiles -of [get_sites URAM288_X${x}Y${y}]]]
    set near [dict create]
    foreach site [get_sites -filter {SITE_TYPE =~ SLICE*} SLICE_X*Y$y0] {
        regexp {SLICE_X(\d+)Y} $site -> sx
        dict set near $sx [expr {[get_property COLUMN [get_tiles -of $site]] - $column}]
    }
    set ranges {}
    foreach side {-1 1} {
        set picked {}
        dict for {sx d} $near {
            if {$d * $side > 0} {lappend picked [list $sx [expr {abs($d)}]]}
        }
        foreach entry [lrange [lsort -integer -index 1 $picked] 0 [expr {$columns - 1}]] {
            lappend ranges "SLICE_X[lindex $entry 0]Y$y0:SLICE_X[lindex $entry 0]Y$y1"
        }
    }
    return $ranges
}
set lane_reads [dict create]
if {$::tpu_uram_read_columns > 0} {
    set reads [get_cells -hier -filter {IS_PRIMITIVE && REF_NAME =~ FD* && \
        NAME =~ */u_memory/gen_uram[*].u_uram/*rsp_rdata_reg[*]}]
    foreach cell $reads name [get_property NAME $reads] {
        if {[regexp {/u_vector/gen_lane\[([0-9]+)\]\.} $name -> lane]} {dict lappend lane_reads $lane $cell}
    }
    if {[dict size $lane_reads] != $lane_count} {
        error "URAM read registers found in [dict size $lane_reads] of $lane_count lanes"
    }
}

set lane 0
for {set x 0} {$x < $uram_columns} {incr x} {
    set in_column [expr {($lane_count - $lane + $uram_columns - $x - 1) / ($uram_columns - $x)}]
    set pitch [expr {$uram_rows / $in_column}]
    if {$pitch < $per_lane} {error "$in_column lanes of $per_lane URAMs do not fit a $uram_rows-row column"}
    for {set i 0} {$i < $in_column} {incr i} {
        set slot [expr {$x % 2 == 0 ? $i : $in_column - 1 - $i}]
        set y [expr {$uram_y0 + $slot * $pitch}]
        set range "URAM288_X${x}Y${y}:URAM288_X${x}Y[expr {$y + $per_lane - 1}]"
        set block [create_pblock pblock_lane_$lane]
        resize_pblock $block -add $range
        set_property PARENT $parent $block
        add_cells_to_pblock $block [dict get $lane_urams $lane]
        puts "TPU_LANE_GRID lane=$lane $range cells=$per_lane"
        if {$::tpu_uram_read_columns > 0} {
            set slices [read_ranges $x $y $per_lane $::tpu_uram_read_columns]
            resize_pblock $block -add $slices
            add_cells_to_pblock $block [dict get $lane_reads $lane]
            puts "TPU_LANE_GRID lane=$lane read registers=[llength [dict get $lane_reads $lane]] in $slices"
        }
        incr lane
    }
}
