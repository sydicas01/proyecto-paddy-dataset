#!/usr/bin/env bash
# ==============================================================================
# Pipeline - Evaluación 1: Paddy Dataset
# ==============================================================================
set -e

echo ">>> 1.1 Limpieza de datos"
mkdir -p data scripts report
curl -sL -o data/paddy.zip https://archive.ics.uci.edu/static/public/1186/paddy+dataset.zip
unzip -o data/paddy.zip -d data/ > /dev/null

# Inspeccionar formato, terminadores de linea y filas iniciales
file data/paddydataset.csv
head -n 5 data/paddydataset.csv | cat -A
wc -l data/paddydataset.csv

# Convertir terminadores a Unix y limpiar nombres de columna
tr -d '\r' < data/paddydataset.csv > data/paddy_unix.csv
wc -l data/paddy_unix.csv

head -n 1 data/paddy_unix.csv | tr '[:upper:]' '[:lower:]' | sed -E 's/[() /]+/_/g; s/_+,/,/g; s/_+$//' > data/header_clean.csv
tail -n +2 data/paddy_unix.csv > data/body_raw.csv
cat data/header_clean.csv data/body_raw.csv > data/paddy_renamed.csv

# Mapeo entre nombres originales y nuevos
paste -d, <(head -n 1 data/paddy_unix.csv | tr ',' '\n') <(head -n 1 data/header_clean.csv | tr ',' '\n') | nl

# Verificar valores faltantes y coherencia (4 tramos de temperatura y rangos)
csvstat data/paddy_renamed.csv --nulls
awk -F, 'NR>1 && ($24>$25 || $26>$27 || $28>$29 || $30>$31) {print "Error temp en fila " NR}' data/paddy_renamed.csv
awk -F, 'NR>1 && ($1<=0 || $44<0 || $45<=0) {print "Error rango en fila " NR}' data/paddy_renamed.csv

# Detectar, contar y eliminar filas duplicadas exactas
tail -n +2 data/paddy_renamed.csv | sort | uniq -d | wc -l
head -n 1 data/paddy_renamed.csv > data/paddy_dedup.csv
tail -n +2 data/paddy_renamed.csv | sort | uniq >> data/paddy_dedup.csv
wc -l data/paddy_dedup.csv

# Crear columnas rendimiento_ha y trash_ha y guardar data/paddy_clean.csv
awk -F, 'BEGIN {OFS=","}
NR==1 { print $0, "rendimiento_ha", "trash_ha" }
NR>1  {
  r_ha = ($1 > 0) ? $45 / $1 : 0;
  t_ha = ($1 > 0) ? $44 / $1 : 0;
  print $0, r_ha, t_ha;
}' data/paddy_dedup.csv > data/paddy_clean.csv
wc -l data/paddy_clean.csv


echo ">>> 1.2 Analisis Exploratorio"
# Estadisticos descriptivos de Hectares, rendimiento total y rendimiento_ha
csvcut -c hectares,paddy_yield_in_kg,rendimiento_ha data/paddy_clean.csv | csvstat

# Cardinalidad: numero de valores distintos por columna
csvstat data/paddy_clean.csv --unique

# Comprobar si las 24 variables de clima toman un unico conjunto de valores por Agriblock
awk -F, 'NR>1 {c=$2; for(i=16;i<=35;i++) c=c","$i; for(i=40;i<=43;i++) c=c","$i; print c}' data/paddy_clean.csv | sort | uniq | cut -d, -f1 | sort | uniq -c

# Comprobar si los insumos divididos por hectarea varian o son constantes
awk -F, 'NR>1 {print $5/$1, $6/$1, $8/$1, $9/$1, $10/$1, $11/$1, $12/$1, $13/$1, $14/$1, $15/$1}' data/paddy_clean.csv | sort | uniq -c
awk -F, 'NR>1 {print $47}' data/paddy_clean.csv | sort | uniq -c

# Distribucion de superficies, rendimiento por categorias y correlaciones
python3 -c "
import pandas as pd
df = pd.read_csv('data/paddy_clean.csv')

print('\n=== DISTRIBUCION DE SUPERFICIES Y RENDIMIENTO MEDIO ===')
sup_stats = df.groupby('hectares').agg(
    registros=('hectares', 'count'),
    total_medio=('paddy_yield_in_kg', 'mean'),
    rend_ha_medio=('rendimiento_ha', 'mean')
)
print(sup_stats)

print('\n=== RENDIMIENTO POR HECTAREA (MEDIA Y DESVIACION ESTANDAR) ===')
for col in ['variety', 'soil_types', 'nursery', 'agriblock']:
    print(f'\n--- Segun {col.upper()} ---')
    print(df.groupby(col)['rendimiento_ha'].agg(['mean', 'std']))

print('\n=== CORRELACION ===')
print(df[['hectares', 'paddy_yield_in_kg', 'rendimiento_ha']].corr())
"

# Visualizaciones desde la linea de comandos
rush plot --x 'factor(hectares)' --y rendimiento_ha --geom boxplot --title "Rendimiento/ha segun Superficie" data/paddy_clean.csv > report/fig_rendimiento_superficie.png 2>/dev/null
rush plot --x variety --y rendimiento_ha --geom boxplot --title "Rendimiento/ha segun Variedad" data/paddy_clean.csv > report/fig_rendimiento_variedad.png 2>/dev/null


echo ">>> 1.3 Modelacion predictiva"
# Particion reproducible 70/30 (semilla 42)
head -n 1 data/paddy_clean.csv > data/header.csv
tail -n +2 data/paddy_clean.csv | shuf --random-source=<(yes 42) > data/paddy_shuf.csv
NTR=$(( $(wc -l < data/paddy_shuf.csv) * 7 / 10 ))
(cat data/header.csv; head -n $NTR data/paddy_shuf.csv) > data/train.csv
(cat data/header.csv; tail -n +$((NTR+1)) data/paddy_shuf.csv) > data/test.csv

# Convertir datos a formato Vowpal Wabbit con awk
for split in train test; do
  awk -F, 'NR>1 {var=$3; gsub(" ", "_", var); print ($46/1000) " |A variety_" var " soil_" $4 " nursery_" $7 " trash_ha:" $47}' data/${split}.csv > data/${split}_A.vw
  awk -F, 'NR>1 {printf "%s |B", ($46/1000); for(i=16; i<=35; i++) printf " c%d:%s", i, $i; for(i=40; i<=43; i++) printf " c%d:%s", i, $i; printf "\n"}' data/${split}.csv > data/${split}_B.vw
  awk -F, 'NR>1 {print ($46/1000) " |C hectares:" $1}' data/${split}.csv > data/${split}_C.vw
  awk -F, 'NR>1 {var=$3; gsub(" ", "_", var); printf "%s |A variety_%s soil_%s nursery_%s trash_ha:%s |B", ($46/1000), var, $4, $7, $47; for(i=16; i<=35; i++) printf " c%d:%s", i, $i; for(i=40; i<=43; i++) printf " c%d:%s", i, $i; printf " |C hectares:%s\n", $1}' data/${split}.csv > data/${split}_D.vw
  awk -F, 'NR>1 {print ($45/1000) " |C hectares:" $1}' data/${split}.csv > data/${split}_Contraste.vw
done

# Entrenar y predecir con Vowpal Wabbit
for m in A B C D Contraste; do
  rm -f data/train_${m}.vw.cache
  vw -d data/train_${m}.vw -f data/model_${m}.vw --loss_function squared -c -k --passes 50 --holdout_off --quiet
  vw -t -i data/model_${m}.vw -d data/test_${m}.vw -p data/pred_${m}_scaled.txt --quiet
  awk '{printf "%.4f\n", $1 * 1000}' data/pred_${m}_scaled.txt > data/pred_${m}.txt
done

# Calcular MAE y R2 en el conjunto de prueba
python3 -c "
def read_col(path, idx):
    with open(path) as f:
        next(f)
        return [float(line.strip().split(',')[idx]) for line in f]

y_test_ha = read_col('data/test.csv', 45)
y_train_ha = read_col('data/train.csv', 45)
y_test_tot = read_col('data/test.csv', 44)

base_pred = sum(y_train_ha) / len(y_train_ha)
preds_base = [base_pred] * len(y_test_ha)

def metrics(y_true, y_pred):
    mae = sum(abs(t - p) for t, p in zip(y_true, y_pred)) / len(y_true)
    mean_y = sum(y_true) / len(y_true)
    ss_tot = sum((t - mean_y)**2 for t in y_true)
    ss_res = sum((t - p)**2 for t, p in zip(y_true, y_pred))
    r2 = 1 - (ss_res / ss_tot) if ss_tot != 0 else 0
    return mae, r2

print('| Modelo         | MAE          | R2          |')
print('| :---           | :---         | :---        |')
mae, r2 = metrics(y_test_ha, preds_base)
print(f'| Base           | {mae:.2f}       | {r2:.4f}     |')
for m in ['A', 'B', 'C', 'D']:
    with open(f'data/pred_{m}.txt') as f:
        preds = [float(l.strip()) for l in f]
    mae, r2 = metrics(y_test_ha, preds)
    print(f'| Modelo {m}       | {mae:.2f}       | {r2:.4f}     |')

with open('data/pred_Contraste.txt') as f:
    preds_c = [float(l.strip()) for l in f]
mae, r2 = metrics(y_test_tot, preds_c)
print(f'\n-> R2 Modelo Contraste (Rend. Total vs Hectareas): {r2:.4f}')
"

echo ">>> 1.4 Ficha de Asesoria"
REGISTROS=$(tail -n +2 data/paddy_clean.csv | wc -l)
REND_MEDIO=$(tail -n +2 data/paddy_clean.csv | awk -F, '{s+=$46; n++} END {printf "%.2f", s/n}')
MEJOR_SUP=$(tail -n +2 data/paddy_clean.csv | awk -F, '{s[$1]+=$46; n[$1]++} END {for(h in s) print h, s[h]/n[h]}' | sort -k2 -nr | head -n1 | cut -d' ' -f1)
R2_SUP=$(paste -d, <(tail -n +2 data/test.csv | cut -d, -f46) data/pred_C.txt | awk -F, '{n++; sy+=$1; sy2+=$1*$1; se+=($1-$2)^2} END {printf "%.4f", 1 - se/(sy2 - sy*sy/n)}')

echo "Programa de Extension Agricola - Ficha de Asesoria" > report/ficha.txt
echo "Asesor: $(whoami)" >> report/ficha.txt
echo "Registros unicos analizados: $REGISTROS" >> report/ficha.txt
echo "Rendimiento medio: $REND_MEDIO kg/ha" >> report/ficha.txt
echo "Superficie de mayor rendimiento medio: $MEJOR_SUP ha" >> report/ficha.txt
echo "R2 del modelo de superficie (prueba): $R2_SUP" >> report/ficha.txt

cat report/ficha.txt

echo ">>> Pipeline ejecutado correctamente."
