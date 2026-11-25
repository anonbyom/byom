set part      $::env(PART)
set out_xo    [file normalize $::env(XO)]
set build_dir [file normalize $::env(PACKAGE_DIR)]
set kernel_name $::env(TOP)
set ip_dir    $build_dir/ip
set proj_dir  $build_dir/proj
set sources [split $::env(VERILOG_SRCS) "\n"]
set params [split $::env(PARAMETERS) "\n"]

foreach path [list $ip_dir $proj_dir $out_xo] {
    if {[file exists $path]} {error "Refusing to overwrite $path"}
}
file mkdir $build_dir

create_project -force kernel_pack $proj_dir -part $part
if {[info exists ::env(VERILOG_DEFINES)] && $::env(VERILOG_DEFINES) ne ""} {
    set_property verilog_define [split $::env(VERILOG_DEFINES) "\n"] [current_fileset]
}
set source_names [dict create]
set includes {}
foreach source $sources {
    set source_name [file tail $source]
    if {[dict exists $source_names $source_name]} {
        error "duplicate packaged source name $source_name: [dict get $source_names $source_name] and $source"
    }
    dict set source_names $source_name $source
    add_files -norecurse $source
    if {[file extension $source] eq ".svh"} {
        set_property file_type {Verilog Header} [get_files $source]
        lappend includes [file dirname $source]
    }
}
set_property include_dirs [lsort -unique $includes] [current_fileset]
if {[info exists ::env(XDC_SRCS)]} {
    foreach constraint [split $::env(XDC_SRCS) "\n"] {
        if {$constraint eq ""} {continue}
        add_files -fileset constrs_1 -norecurse $constraint
        set_property PROCESSING_ORDER EARLY [get_files $constraint]
    }
}
set_property top $kernel_name [current_fileset]
update_compile_order -fileset sources_1
# mem_bytewrite OREG (VMEM_URAM_OREG) instantiates xpm_memory_tdpram.
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]

ipx::package_project -root_dir $ip_dir -vendor user -library tpu -taxonomy /KernelIP -import_files -set_current true
set core [ipx::current_core]
set_property core_revision 1 $core
set_property sdx_kernel true $core
set_property sdx_kernel_type rtl $core
set_property ipi_drc {ignore_freq_hz true} $core
set_property vitis_drc {ctrl_protocol ap_ctrl_hs} $core

foreach param $params {
    lassign [split $param =] parameter value
    set user_parameter [ipx::get_user_parameters $parameter -of_objects $core]
    set hdl_parameter [ipx::get_hdl_parameters $parameter -of_objects $core]
    if {[llength $user_parameter] != 1 || [llength $hdl_parameter] != 1} {
        error "expected one packaged user and HDL parameter named $parameter"
    }
    set_property value $value $user_parameter
    set_property value $value $hdl_parameter
}

ipx::associate_bus_interfaces -busif s_axi_control -clock ap_clk $core
for {set channel 0} {$channel < 32} {incr channel} {
    set name m_axi_gmem${channel}
    ipx::associate_bus_interfaces -busif $name -clock ap_clk $core
    set space [ipx::get_address_spaces -quiet $name -of_objects $core]
    if {[llength $space] == 0} {
        set space [ipx::add_address_space $name $core]
    }
    set_property range 16E $space
    set_property width 64 $space
    set_property master_address_space_ref $name [ipx::get_bus_interfaces $name -of_objects $core]
}

foreach map [ipx::get_memory_maps * -of_objects $core] {
    ipx::remove_memory_map [lindex $map 2] $core
}
set map [ipx::add_memory_map s_axi_control $core]
set_property slave_memory_map_ref s_axi_control [ipx::get_bus_interfaces s_axi_control -of_objects $core]
set block [ipx::add_address_block reg0 $map]
set_property range 512 $block
set_property width 32 $block

foreach {name offset} {
    CTRL               0x000
    boot_external_addr 0x010
    boot_imem_addr     0x014
    boot_length        0x018
} {
    set reg [ipx::add_register $name $block]
    set_property address_offset $offset $reg
    set_property size 32 $reg
}

# A matrix unit with a run-time configuration (MXU_MODE_WORD) takes it as the kernel argument mxu_mode
    set reg [ipx::add_register mxu_mode $block]
    set_property address_offset 0x01c $reg
    set_property size 32 $reg
}

for {set channel 0} {$channel < 32} {incr channel} {
    set reg [ipx::add_register hbm${channel} $block]
    set_property address_offset [expr {0x20 + 8 * $channel}] $reg
    set_property size 64 $reg
    ipx::add_register_parameter ASSOCIATED_BUSIF $reg
    set_property value m_axi_gmem${channel} [ipx::get_register_parameters ASSOCIATED_BUSIF -of_objects $reg]
}

# v++ synthesizes the kernel IP again in its own project, which does not see this project's verilog_define.
if {[info exists ::env(VERILOG_DEFINES)] && $::env(VERILOG_DEFINES) ne ""} {
    set header ""
    foreach define [split $::env(VERILOG_DEFINES) "\n"] {
        if {$define eq ""} {continue}
        lassign [split $define =] name value
        append header "`define $name $value\n"
    }
    set imported [glob -nocomplain -directory $ip_dir/src *.sv]
    if {[llength $imported] == 0} {error "no imported sources in $ip_dir/src for VERILOG_DEFINES"}
    foreach path $imported {
        set file [open $path r]; set text [read $file]; close $file
        set file [open $path w]; puts -nonewline $file "$header$text"; close $file
    }
}

ipx::create_xgui_files $core
ipx::update_checksums $core
ipx::save_core $core
ipx::check_integrity -quiet $core

package_xo -force -xo_path $out_xo -kernel_name $kernel_name -ip_directory $ip_dir -ctrl_protocol ap_ctrl_hs
