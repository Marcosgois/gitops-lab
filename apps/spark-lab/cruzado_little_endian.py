#!/usr/bin/env python3
"""Prova cruzada entre arquiteturas para o spark-lab (roda numa máquina little-endian: x86 ou ARM).

  gravar N  — grava de_little_endian/vendas_{snappy,zstd}.parquet com as MESMAS fórmulas do
              teste-parquet-s3.scala (o Spark em s390x lê e confere).
  ler N     — lê o Parquet que o Spark em s390x gravou (de_s390x/vendas_*) e confere contra as
              fórmulas calculadas aqui, sem depender do Spark.
  espiar P  — (demo, segundos) abre UM arquivo da pasta P do bucket gravada pelo s390x e mostra quem
              gravou, a compressão e as primeiras linhas.

Requer pyarrow e as variáveis S3_ENDPOINT (http://host), BUCKET_NAME, AWS_ACCESS_KEY_ID,
AWS_SECRET_ACCESS_KEY (as do ObjectBucketClaim `dados`).
"""
import datetime as dt, decimal, os, sys, time
import numpy as np
import pyarrow as pa, pyarrow.compute as pc, pyarrow.dataset as ds, pyarrow.parquet as pq
from pyarrow import fs

s3 = fs.S3FileSystem(endpoint_override=os.environ["S3_ENDPOINT"], region="us-east-1",
                     access_key=os.environ["AWS_ACCESS_KEY_ID"], secret_key=os.environ["AWS_SECRET_ACCESS_KEY"])
bucket = os.environ["BUCKET_NAME"]


def esperado(n):
    """Resumo calculado direto das fórmulas (inteiros exatos; a soma de raiz em float64)."""
    i = np.arange(n, dtype=np.int64)
    cents = (i * 7919) % 100000
    v = i % 50000
    digitos = 1 + (v >= 10) + (v >= 100) + (v >= 1000) + (v >= 10000)
    d = i % 2000
    return dict(linhas=n, soma_id=int(i.sum()), soma_valor=decimal.Decimal(int(cents.sum())).scaleb(-2),
                soma_x=int(((i * 2654435761) % 1000000007).sum()), clientes=int(min(n, 1000)),
                data_min=dt.date(2020, 1, 1) + dt.timedelta(int(d.min())),
                data_max=dt.date(2020, 1, 1) + dt.timedelta(int(d.max())),
                flags=int((i % 7 == 0).sum()), soma_len_desc=int(5 * n + digitos.sum()),
                soma_raiz=float(np.sqrt(i.astype(np.float64)).sum()))


def tabela(n):
    i = np.arange(n, dtype=np.int64)
    valor = pa.array((decimal.Decimal(int(c)).scaleb(-2) for c in (i * 7919) % 100000), type=pa.decimal128(12, 2))
    return pa.table({
        "id": i, "cliente": (i % 1000).astype(np.int32), "valor": valor,
        "x": (i * 2654435761) % 1000000007,
        "data": pa.array(np.datetime64("2020-01-01") + (i % 2000).astype("timedelta64[D]"), type=pa.date32()),
        "descricao": pa.array(np.char.add("item-", (i % 50000).astype(str))),
        "flag": i % 7 == 0, "raiz": np.sqrt(i.astype(np.float64))})


def resumo(t):
    return dict(linhas=t.num_rows, soma_id=pc.sum(t["id"]).as_py(), soma_valor=pc.sum(t["valor"]).as_py(),
                soma_x=pc.sum(t["x"]).as_py(), clientes=pc.count_distinct(t["cliente"]).as_py(),
                data_min=pc.min(t["data"]).as_py(), data_max=pc.max(t["data"]).as_py(),
                flags=pc.sum(pc.cast(t["flag"], pa.int64())).as_py(),
                soma_len_desc=pc.sum(pc.utf8_length(t["descricao"])).as_py(), soma_raiz=pc.sum(t["raiz"]).as_py())


def confere(rotulo, esp, obt):
    ok = all(abs(esp[k] - obt[k]) <= 1e-9 * max(1.0, abs(esp[k])) if isinstance(esp[k], float) else esp[k] == obt[k]
             for k in esp)
    print(f"{'OK   ' if ok else 'FALHA'} {rotulo}: " + " ".join(f"{k}={obt[k]}" for k in esp))
    if not ok:
        print("      esperado: " + " ".join(f"{k}={esp[k]}" for k in esp))
    return ok


modo, arg = sys.argv[1], sys.argv[2]
n = int(arg) if arg.isdigit() else 0
print(f"máquina: {os.uname().machine}, byteorder={sys.byteorder}, pyarrow {pa.__version__}")
if modo == "espiar":
    arqs = sorted((f for f in s3.get_file_info(fs.FileSelector(f"{bucket}/{arg}")) if f.base_name.endswith(".parquet")),
                  key=lambda f: f.base_name)
    f = pq.ParquetFile(arqs[0].path, filesystem=s3)
    m = f.metadata
    print(f"pasta {arg}: {len(arqs)} arquivos Parquet, {sum(a.size for a in arqs) / 2**30:.2f} GiB")
    print(f"arquivo {arqs[0].base_name}: {m.num_rows} linhas, gravado por: {m.created_by}, "
          f"compressão: {m.row_group(0).column(0).compression}")
    for r in f.read_row_group(0).slice(0, 5).to_pylist():
        print("  " + " | ".join(f"{k}={v}" for k, v in r.items()))
elif modo == "gravar":
    t = tabela(n)
    for codec in ("snappy", "zstd"):
        t0 = time.time()
        pq.write_table(t, f"{bucket}/de_little_endian/vendas_{codec}.parquet", filesystem=s3, compression=codec)
        print(f"gravado de_little_endian/vendas_{codec}.parquet ({n} linhas) em {time.time() - t0:.1f} s")
else:
    esp, ok = esperado(n), True
    for codec in ("snappy", "zstd"):
        t0 = time.time()
        t = ds.dataset(f"{bucket}/de_s390x/vendas_{codec}", filesystem=s3, format="parquet").to_table()
        ok &= confere(f"Parquet gravado pelo s390x ({codec}), lido em {sys.byteorder}-endian em {time.time() - t0:.0f} s",
                      esp, resumo(t))
        meta = pq.ParquetFile(f"{bucket}/de_s390x/vendas_{codec}/" + [f.base_name for f in s3.get_file_info(
            fs.FileSelector(f"{bucket}/de_s390x/vendas_{codec}")) if f.base_name.endswith(".parquet")][0], filesystem=s3).metadata
        print(f"      gravado por: {meta.created_by}; compressão: {meta.row_group(0).column(0).compression}")
    print("RESULTADO:", "TUDO CONFERE" if ok else "HÁ DIVERGÊNCIA")
    sys.exit(0 if ok else 1)
