# Synthesis boundaries for the floorplan
set blocks [get_cells -hier -filter {REF_NAME == vlane || REF_NAME =~ vlane_* || ORIG_REF_NAME == vlane || \
    REF_NAME == vector_dma_channel || REF_NAME =~ vector_dma_channel_* || ORIG_REF_NAME == vector_dma_channel || \
    REF_NAME =~ vector_mxu* || ORIG_REF_NAME == vector_mxu || REF_NAME == mxu || ORIG_REF_NAME == mxu || \
    REF_NAME == vector_issue || ORIG_REF_NAME == vector_issue || REF_NAME == scalar_unit || ORIG_REF_NAME == scalar_unit || \
    REF_NAME == dma_unit || ORIG_REF_NAME == dma_unit || REF_NAME == xlu || ORIG_REF_NAME == xlu}]
set_property KEEP_HIERARCHY true $blocks

set_property KEEP_HIERARCHY true [get_cells -hier -regexp {.*gen_transpose.*gen_input.*u_(tx|rx)_(data|valid)$}]
set_property KEEP_HIERARCHY true [get_cells -hier -regexp {.*u_issue/u_return$}]
set_property -quiet KEEP_HIERARCHY true [get_cells -hier -regexp {.*gen_feed.*gen_crossing.*u_stage$}]
set_property -quiet KEEP_HIERARCHY true [get_cells -hier -regexp {.*gen_mxu.*gen_crossing.u_result_(tx|rx)$}]
set_property -quiet KEEP_HIERARCHY true [get_cells -hier -regexp {.*gen_mxu.*gen_command_crossing.u_(freed_)?(tx|rx)$}]
set_property -quiet SHREG_EXTRACT NO [get_cells -hier -regexp {.*gen_transpose.*gen_input.*u_(tx|rx)_(data|valid)/.*regs_reg.*}]
set_property -quiet SHREG_EXTRACT NO [get_cells -hier -regexp {.*u_issue/u_return/.*regs_reg.*}]
