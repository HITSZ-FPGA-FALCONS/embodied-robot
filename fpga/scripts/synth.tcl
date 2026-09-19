# ============================================================================
#  Gowin 命令行综合脚本
# ----------------------------------------------------------------------------
#  用途：不打开 IDE 就能综合，便于批量验证与将来接入 CI
#  执行：gw_sh.exe fpga/scripts/synth.tcl
#        （gw_sh.exe 在 <Gowin安装目录>/IDE/bin/ 下）
#
#  ⚠️ 路径必须全 ASCII —— GowinSynthesis 处理不了中文路径，会报
#     "ERROR (SP0002): Corrupted project file"。这是实测确认的。
#
#  本流程已于 2026-09-19 在本机验证通过（GW5AT-138B 目标，综合 100% 完成）。
# ============================================================================

# ── 配置区：按项目实际修改 ──────────────────────────────────────────────────

set TOP_MODULE   "led_test"
set RTL_FILES    [list "../../rtl/led_test.v"]
set DEVICE_PN    "GW5AT-LV138PG484AC1/I0"
set DEVICE_NAME  "GW5AT-138C"
set DEVICE_VER   "C"

# 如需做完整实现（布局布线 + 生成 bitstream），把下面的 run syn 换成 run all
# 注意：run all 耗时明显更长

# ── 执行区 ──────────────────────────────────────────────────────────────────

puts "=== 目标器件 ==="
puts "  part number : $DEVICE_PN"
puts "  device name : $DEVICE_NAME  (version $DEVICE_VER)"
puts "  顶层模块    : $TOP_MODULE"
puts ""

# 器件：同料号存在 138B / 138C 两个晶圆版本，必须用 -name 指定，否则报
# "there are more than one device named ..."
set_device -name $DEVICE_NAME $DEVICE_PN -device_version $DEVICE_VER

# 添加源文件
foreach f $RTL_FILES {
    puts "  add file: $f"
    add_file $f
}

set_option -top_module $TOP_MODULE

puts ""
puts "=== 开始综合 ==="
run syn

puts ""
puts "=== 综合结束 ==="
puts "产物目录: impl/gwsynthesis/"
puts "  project.vg          网表"
puts "  project_syn.rpt.html 综合报告（面积 / 资源占用）"
