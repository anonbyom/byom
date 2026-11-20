// Emit Gemmini's Mesh unmodified behind a flat-port top (FlatMesh) for BYOM's Gemmini matrix unit
ThisBuild / scalaVersion := "2.13.10"

def checkout(name: String) = file(sys.env.getOrElse(name,
  sys.error(s"$name is not set: run examples/gemmini/generate.py, which clones the pinned sources")))
val gemminiSrc = checkout("GEMMINI_SRC") / "src" / "main" / "scala" / "gemmini"
val hardfloatSrc = checkout("HARDFLOAT_SRC") / "hardfloat" / "src" / "main" / "scala"

val meshFiles = Seq("Mesh", "Tile", "PE", "Arithmetic", "Util", "Dataflow")

lazy val root = (project in file("."))
  .settings(
    name := "gemmini-flat-mesh",
    libraryDependencies += "edu.berkeley.cs" %% "chisel3" % "3.6.0",
    addCompilerPlugin("edu.berkeley.cs" % "chisel3-plugin" % "3.6.0" cross CrossVersion.full),
    scalacOptions ++= Seq("-language:reflectiveCalls", "-deprecation", "-feature"),
    Compile / unmanagedSources ++= meshFiles.map(f => gemminiSrc / s"$f.scala") ++
      (hardfloatSrc ** "*.scala").get,
    run / fork := true,
    run / javaOptions ++= Seq("-Xss64m", "-Xmx12g"),
  )
