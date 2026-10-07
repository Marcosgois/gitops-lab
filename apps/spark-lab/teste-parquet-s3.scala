// Prova de viabilidade: Spark SQL em s390x (big-endian) lendo e gravando Parquet no S3.
//
// 1. Gera LINHAS linhas sintéticas (fórmulas determinísticas), grava em Parquet SNAPPY e ZSTD no S3,
//    relê e compara um resumo (contagem, somas exatas, distintos, datas) com o resumo do dado gerado.
// 2. Se existir s3a://<bucket>/de_little_endian/ (gravado por outra arquitetura com as MESMAS fórmulas),
//    lê e compara com o que o próprio Spark gera — prova a troca de arquivos entre arquiteturas.
// 3. Roda duas consultas de exemplo e imprime os tempos (número de laboratório, não comparação).
//
// Uso: spark-shell --master local[*] < teste-parquet-s3.scala   (variáveis: LINHAS, LINHAS_LE, BUCKET_NAME)
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.functions._

val linhas   = sys.env.getOrElse("LINHAS", "50000000").toLong
val linhasLE = sys.env.getOrElse("LINHAS_LE", "5000000").toLong
val base     = s"s3a://${sys.env("BUCKET_NAME")}"
val saida    = sys.env.getOrElse("SAIDA", "de_s390x")   // pasta de saída no bucket
println(s"### executores=${spark.sparkContext.getExecutorMemoryStatus.size - 1} master=${spark.sparkContext.master}")
println(s"### os.arch=${System.getProperty("os.arch")} endian=${java.nio.ByteOrder.nativeOrder} java=${System.getProperty("java.version")} spark=${spark.version} linhas=$linhas")

def tempo[A](nome: String)(f: => A): A = {
  val t0 = System.nanoTime; val r = f
  println(f"### tempo $nome%-34s ${(System.nanoTime - t0) / 1e9}%7.1f s"); r
}

// Mesmas fórmulas em gera_little_endian.py (lado x86/ARM)
def gerar(n: Long): DataFrame = spark.range(n).select(
  col("id"),
  (col("id") % 1000).cast("int").as("cliente"),
  ((col("id") * 7919) % 100000).cast("decimal(12,2)").divide(100).cast("decimal(12,2)").as("valor"),
  ((col("id") * 2654435761L) % 1000000007L).as("x"),
  expr("date_add(date'2020-01-01', cast(id % 2000 as int))").as("data"),
  concat(lit("item-"), (col("id") % 50000).cast("string")).as("descricao"),
  (col("id") % 7 === 0).as("flag"),
  sqrt(col("id").cast("double")).as("raiz"))

def resumo(df: DataFrame): Seq[Any] = df.agg(
  count(lit(1)), sum("id"), sum("valor"), sum("x"), countDistinct("cliente"),
  min("data"), max("data"), sum(when(col("flag"), 1).otherwise(0)), sum(length(col("descricao"))),
  sum("raiz")).head.toSeq

val nomes = Seq("linhas", "soma_id", "soma_valor", "soma_x", "clientes", "data_min", "data_max", "flags", "soma_len_desc", "soma_raiz")
def confere(rotulo: String, esperado: Seq[Any], obtido: Seq[Any]): Boolean = {
  val ok = nomes.indices.forall { i =>
    (esperado(i), obtido(i)) match {
      case (a: Double, b: Double) => math.abs(a - b) <= 1e-9 * math.max(1.0, math.abs(a)) // soma de double: ordem pode variar
      case (a, b) => a == b
    }
  }
  println(s"### ${if (ok) "OK   " else "FALHA"} $rotulo: " + nomes.zip(obtido).map { case (k, v) => s"$k=$v" }.mkString(" "))
  if (!ok) println("###       esperado: " + nomes.zip(esperado).map { case (k, v) => s"$k=$v" }.mkString(" "))
  ok
}

// Tudo num bloco só: no REPL, um erro aborta só a instrução em que ocorreu — fora de um bloco, o teste
// seguiria e terminaria "verde". Aqui qualquer exceção encerra o processo com código 2.
try {
  val esperado = tempo("resumo do dado gerado (memória)")(resumo(gerar(linhas)))
  var tudoOk = confere("gerado em memória", esperado, esperado)
  for (codec <- Seq("snappy", "zstd")) {
    val dest = s"$base/$saida/vendas_$codec"
    tempo(s"gravar $linhas linhas ($codec)")(gerar(linhas).write.mode("overwrite").option("compression", codec).parquet(dest))
    tudoOk &= confere(s"relido do S3 ($codec)", esperado, tempo(s"reler e resumir ($codec)")(resumo(spark.read.parquet(dest))))
  }

  // Arquivos gravados por máquina little-endian (x86/ARM) com as mesmas fórmulas
  val fs = org.apache.hadoop.fs.FileSystem.get(new java.net.URI(base), spark.sparkContext.hadoopConfiguration)
  for (codec <- Seq("snappy", "zstd")) {
    val p = new org.apache.hadoop.fs.Path(s"$base/de_little_endian/vendas_$codec.parquet")
    if (fs.exists(p)) tudoOk &= confere(s"gravado em little-endian ($codec)", resumo(gerar(linhasLE)), resumo(spark.read.parquet(p.toString)))
    else println(s"### (sem arquivo little-endian $codec em $p)")
  }

  // Consultas de exemplo (tempo de laboratório)
  spark.read.parquet(s"$base/$saida/vendas_zstd").createOrReplaceTempView("vendas")
  tempo("consulta: top 5 clientes em 2021")(spark.sql(
    "select cliente, sum(valor) total, count(*) n from vendas where data between date'2021-01-01' and date'2021-12-31' group by cliente order by total desc limit 5").show(false))
  tempo("consulta: faturamento por mês")(spark.sql(
    "select date_trunc('month', data) mes, sum(valor) total from vendas group by 1 order by 1").show(3, false))
  println(s"### RESULTADO FINAL: ${if (tudoOk) "TUDO CONFERE" else "HÁ DIVERGÊNCIA"}")
  System.exit(if (tudoOk) 0 else 1)
} catch {
  case e: Throwable =>
    println(s"### RESULTADO FINAL: ERRO — ${e.getClass.getName}: ${e.getMessage}")
    e.printStackTrace()
    System.exit(2)
}
