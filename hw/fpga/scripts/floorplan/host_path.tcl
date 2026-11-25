# A precaution for the platform shell. The host's PCIe DMA reaches HBM port 12 through register stages in each
# SLR (250 MHz, a clock Vitis cannot lower). With a crowded SLR1 the placer once put the SLR1 stage at its top centre
# and that path failed timing. Pin the stages where passing builds had them, SLR2's bottom right, SLR1's right edge.
set host_path level0_i/ulp/hmss_0/inst/path_12
if {![llength [get_cells -quiet $host_path]]} {error "Host HBM path $host_path not found"}
foreach {stage parent ranges} {
    slr_master pblock_dynamic_SLR2 {CLOCKREGION_X5Y8:CLOCKREGION_X6Y8}
    slr_middle pblock_dynamic_SLR1 {
        CLOCKREGION_X5Y4:CLOCKREGION_X5Y7
        SLICE_X176Y300:SLICE_X196Y419
        SLICE_X176Y240:SLICE_X181Y299 SLICE_X183Y240:SLICE_X193Y299 SLICE_X195Y240:SLICE_X196Y299
        SLICE_X176Y420:SLICE_X181Y479 SLICE_X183Y420:SLICE_X193Y479 SLICE_X195Y420:SLICE_X196Y479
        LAGUNA_X24Y120:LAGUNA_X27Y359
    }
} {
    set host_cells [get_cells -hier -filter "IS_PRIMITIVE && NAME =~ $host_path/*triple_slr.*.$stage/*"]
    if {![llength $host_cells]} {error "No $stage cells under $host_path"}
    set block [create_pblock pblock_host_path_$stage]
    resize_pblock $block -add $ranges
    set_property PARENT [get_pblocks $parent] $block
    add_cells_to_pblock $block $host_cells
    puts "TPU_HOST_PATH $stage cells=[llength $host_cells] -> $block"
}
