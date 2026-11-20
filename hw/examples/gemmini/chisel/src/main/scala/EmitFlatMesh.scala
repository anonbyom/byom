package gemmini

import java.nio.file.{Files, Paths}
import chisel3._
import chisel3.util._

case class MeshConfig(
  dim: Int         = 32,
  tile: Int        = 1,
  tileLatency: Int = 0,
  outputDelay: Int = 1,
  inputWidth: Int  = 8,
  outputWidth: Int = 20,
  accWidth: Int    = 32,
  dataflow: String = "ws"
) {

  require(dim % tile == 0, s"tile $tile does not divide dim $dim")
  require(Set("ws", "os", "both").contains(dataflow), s"dataflow $dataflow is not ws, os or both")
  val df = dataflow match { case "os" => Dataflow.OS; case "both" => Dataflow.BOTH; case _ => Dataflow.WS }
  val mesh = dim / tile
  val maxMatmuls = (5 * (((tileLatency + 1).toFloat / tile) max 1.0f)).ceil.toInt
  val treeReduction = df == Dataflow.WS && tile > 1
  val name = s"int${inputWidth}_${dataflow}_d${dim}_t${tile}_l${tileLatency}_o${outputDelay}" +
    (if (treeReduction) "_tr" else "") + (if (outputWidth != 20) s"_out$outputWidth" else "")
}

// Gemmini's Mesh, unmodified, behind one bus per signal so that the ports do not depend on the configuration
// element i of every other bus is mesh column i / tile, tile column i % tile. Element 0 is in the low bits.
class FlatMesh(c: MeshConfig) extends Module {
  val inputType  = SInt(c.inputWidth.W)
  val outputType = SInt(c.outputWidth.W)
  val accType    = SInt(c.accWidth.W)
  val idW        = log2Up(c.maxMatmuls)
  val shiftW     = log2Up(c.accWidth)
  val n          = c.dim

  val io = IO(new Bundle {
    val in_a          = Input(UInt((n * c.inputWidth).W))
    val in_b          = Input(UInt((n * c.inputWidth).W))
    val in_d          = Input(UInt((n * c.inputWidth).W))
    val in_dataflow   = Input(UInt(n.W))
    val in_propagate  = Input(UInt(n.W))
    val in_shift      = Input(UInt((n * shiftW).W))
    val in_id         = Input(UInt((n * idW).W))
    val in_last       = Input(UInt(n.W))
    val in_valid      = Input(UInt(n.W))
    val out_b         = Output(UInt((n * c.outputWidth).W))
    val out_c         = Output(UInt((n * c.outputWidth).W))
    val out_dataflow  = Output(UInt(n.W))
    val out_propagate = Output(UInt(n.W))
    val out_shift     = Output(UInt((n * shiftW).W))
    val out_id        = Output(UInt((n * idW).W))
    val out_last      = Output(UInt(n.W))
    val out_valid     = Output(UInt(n.W))
  })

  val mesh = Module(new Mesh(inputType, inputType, outputType, accType, c.df, c.treeReduction, c.tileLatency,
    c.maxMatmuls, c.outputDelay, c.tile, c.tile, c.mesh, c.mesh))

  def elems[D <: Data](bus: UInt, t: D): Vec[D] = bus.asTypeOf(Vec(n, t))
  def at[D <: Data](v: Vec[Vec[D]], i: Int): D = v(i / c.tile)(i % c.tile)
  val a     = elems(io.in_a, inputType)
  val b     = elems(io.in_b, inputType)
  val d     = elems(io.in_d, inputType)
  val df    = elems(io.in_dataflow, UInt(1.W))
  val prop  = elems(io.in_propagate, UInt(1.W))
  val shift = elems(io.in_shift, UInt(shiftW.W))
  val id    = elems(io.in_id, UInt(idW.W))
  val last  = elems(io.in_last, Bool())
  val valid = elems(io.in_valid, Bool())

  for (i <- 0 until n) {
    at(mesh.io.in_a, i)                 := a(i)
    at(mesh.io.in_b, i)                 := b(i)
    at(mesh.io.in_d, i)                 := d(i)
    at(mesh.io.in_control, i).dataflow  := df(i)
    at(mesh.io.in_control, i).propagate := prop(i)
    at(mesh.io.in_control, i).shift     := shift(i)
    at(mesh.io.in_id, i)                := id(i)
    at(mesh.io.in_last, i)              := last(i)
    at(mesh.io.in_valid, i)             := valid(i)
  }

  io.out_b         := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_b, i))).asUInt
  io.out_c         := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_c, i))).asUInt
  io.out_dataflow  := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_control, i).dataflow)).asUInt
  io.out_propagate := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_control, i).propagate)).asUInt
  io.out_shift     := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_control, i).shift)).asUInt
  io.out_id        := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_id, i))).asUInt
  io.out_last      := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_last, i))).asUInt
  io.out_valid     := VecInit(Seq.tabulate(n)(i => at(mesh.io.out_valid, i))).asUInt
}

object EmitFlatMesh extends App {
  val root = args.headOption.getOrElse(".")
  for (spec <- args.drop(1).toSeq.padTo(1, "")) {
    val raw = spec.split(",").filter(_.nonEmpty).map { p => val Array(k, v) = p.split("="); k -> v }.toMap
    val known = Set("dim", "tile", "tile_latency", "output_delay", "input_width", "output_width", "acc_width",
      "dataflow")
    require(raw.keySet.subsetOf(known), s"unknown keys ${raw.keySet -- known}")
    val kv = (raw - "dataflow").map { case (k, v) => k -> v.toInt }
    val d = MeshConfig()
    val c = MeshConfig(kv.getOrElse("dim", d.dim), kv.getOrElse("tile", d.tile),
      kv.getOrElse("tile_latency", d.tileLatency), kv.getOrElse("output_delay", d.outputDelay),
      kv.getOrElse("input_width", d.inputWidth), kv.getOrElse("output_width", d.outputWidth),
      kv.getOrElse("acc_width", d.accWidth), raw.getOrElse("dataflow", d.dataflow))
    val dir = Paths.get(root, c.name)
    Files.createDirectories(dir)
    (new chisel3.stage.ChiselStage).emitVerilog(new FlatMesh(c), Array("--target-dir", dir.toString))
    Seq(".fir", ".anno.json").foreach(ext => Files.deleteIfExists(dir.resolve("FlatMesh" + ext)))
    val params = Seq("name" -> s"\"${c.name}\"", "dataflow" -> s"\"${c.dataflow}\"", "dim" -> c.dim, "tile" -> c.tile,
      "mesh" -> c.mesh, "tree_reduction" -> c.treeReduction, "tile_latency" -> c.tileLatency,
      "output_delay" -> c.outputDelay,
      "input_width" -> c.inputWidth, "output_width" -> c.outputWidth, "acc_width" -> c.accWidth,
      "max_simultaneous_matmuls" -> c.maxMatmuls, "id_width" -> log2Up(c.maxMatmuls),
      "shift_width" -> log2Up(c.accWidth))
    Files.writeString(dir.resolve("params.json"),
      params.map { case (k, v) => s"  \"$k\": $v" }.mkString("{\n", ",\n", "\n}\n"))
    println(s"emitted ${c.name}")
  }
}
