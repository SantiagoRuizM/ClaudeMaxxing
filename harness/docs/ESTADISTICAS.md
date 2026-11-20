# Estadísticas de los ambientes (para más adelante)

> Escrito el 2026-11-07. Es un plan: nada de esto está implementado todavía. Lo que sí existe hoy es `run/history.json` (conteos de transiciones y segundos por día) y `run/detect.json` (el último veredicto de `env.js detect`), que ClaudeMaxxing dibuja como grafo en su sección Ambientes.

Cambiar de ambiente es una **cadena de Markov**: cada ambiente es un estado y cada cambio, una transición. Como además se mide cuánto tiempo se pasa en cada uno, el modelo exacto es un **proceso semi-Markov**: una cadena de saltos (¿a dónde voy después?) más un tiempo de permanencia por estado. Encender el ambiente que ya está encendido no cuenta como transición, así que no hay transiciones de un estado a sí mismo.

---

## 0. Primero: guardar cada evento (lo único que no se puede recuperar después)

`history.json` guarda **totales**. Con eso alcanza para las secciones 1, 2, 3 y 6, pero no para lo demás: secuencias, hora del día, distribución de las duraciones ni cómo se cambió. Hay que empezar cuanto antes un registro que solo se añade, `run/events.jsonl`, con una línea JSON por evento:

```jsonl
{"type":"stint","id":"trabajo","start":"2026-11-07T09:02:11-05:00","end":"2026-11-07T10:31:40-05:00","from":"startday","to":"atlas","via":"manual"}
{"type":"detect","at":"2026-11-07T10:20:03-05:00","active":"trabajo","suggestion":"atlas","confidence":0.86,"judge":"jev","fingerprint":"6240c15d8376e35f"}
{"type":"offer","at":"2026-11-07T10:20:15-05:00","active":"trabajo","suggestion":"atlas","answer":"yes"}
```

- `stint`: un tramo en un ambiente. Se escribe al cerrarlo (al apagarlo o al encender otro), en el mismo punto de `main()` de `env.js` donde hoy se llama a `recordSwitch`. `via` indica cómo se entró: `manual` (CLI), `hub` (clic en la bolita) u `offer` (el aviso). Para saberlo, ClaudeMaxxing puede pasar `--via hub|offer` al lanzar `env.js`.
- `detect`: cada veredicto nuevo (no los `cached`), escrito desde `detect()`.
- `offer`: la respuesta al aviso de ClaudeMaxxing (`yes` o `no`). Lo escribe la bandeja (`Invoke-HarnessWatch`) en el mismo archivo, o en uno propio si no se quiere compartir.
- `history.json` se sigue manteniendo, porque el grafo lo lee rápido. Si algún día se pierde, se puede reconstruir desde `events.jsonl`.

**Volumen:** hay unos 5 cambios al día, así que una matriz de 6×6 necesita **varias semanas** para ser fiable. Las detecciones solo se registran cuando cambia la huella: unas decenas al día como mucho.

---

## 1. Matriz de transición P

```
P[i][j] = n(i→j) / Σ_k n(i→k)
```

Cada fila responde a "cuando estoy en i, ¿a dónde me voy?".

- **Suavizado:** con pocos datos hay que usar Laplace / un prior de Dirichlet, `P[i][j] = (n(i→j) + α) / (Σ_k n(i→k) + α·(N−1))` con α = 0,5 o 1, y nunca la diagonal.
- **Confianza:** no mostrar como dato una fila con menos de unas **10 salidas**; marcarla como "pocos datos".
- **Vista:** un mapa de calor de 6×6. La fila es el origen y la columna el destino.
- **Fuente:** `history.json → edges`. Ya se puede calcular hoy.

## 2. Distribución estacionaria π y reparto real del tiempo

- π resuelve `π = π·P` con `Σπ = 1`: la proporción de **visitas** que recibe cada ambiente a largo plazo. Con 6 estados basta la iteración de potencias (multiplicar un vector por P hasta que converja).
- **Proporción de tiempo a largo plazo** (semi-Markov): `t_i = π_i·d_i / Σ_k π_k·d_k`, donde `d_i` es la duración media en i (sección 3).
- **Lo útil:** compararlo con un reparto **objetivo** que se declare (por ejemplo `{"trabajo": 0.5, "atlas": 0.25, …}` en un archivo propio) y mostrar la brecha.
- **Fuente:** `edges` + `time`, o sea `history.json`. Ya se puede calcular hoy.

## 3. Duración media de cada tramo (capacidad de foco)

- `d_i = segundos totales en i / número de entradas a i`. Las entradas a i son la suma de la columna i de `edges`, más 1 si fue el primer ambiente encendido.
- Es una métrica que se puede ir mejorando: "en Trabajo aguantas 52 min de media antes de cambiar".
- La **distribución** completa (mediana, p90, tramos cortos de menos de 10 min) necesita los `stint` de `events.jsonl`. Si se parece a una exponencial, el proceso se aproxima a una cadena de Markov en tiempo continuo con matriz de tasas Q (`Q[i][j] = P[i][j] / d_i`).

## 4. Tiempos de llegada y de retorno

- **Retorno:** `1/π_i` es el número medio de cambios que tardas en volver a i.
- **Llegada:** el número esperado de cambios para llegar a j desde i. Se calcula resolviendo `h_j = 0`, `h_i = 1 + Σ_k P[i][k]·h_k` para i ≠ j. El caso interesante es **desde Trabajo o Atlas hasta Gaming**, que mide la procrastinación. Con duraciones, se convierte a tiempo: "tardas de media 2 h 40 min en caer en Gaming desde que entras a trabajar".

## 5. EndDay como estado absorbente (el día como cadena)

Hay que cortar la secuencia por días: cada día empieza en su primer ambiente y termina en EndDay, que actúa como estado absorbente. Con la matriz fundamental `N = (I − Q_t)^-1`, donde `Q_t` son las transiciones entre estados no absorbentes, salen:

- `N·1`: los cambios esperados por día antes de cerrar;
- la probabilidad de pasar por Gaming antes de EndDay;
- desde qué ambiente es más probable que el día "se te escape".

**Necesita** los `stint` (secuencias por día).

## 6. Entropía (orden frente a caos)

- **Por fila:** `H_i = −Σ_j P[i][j]·log2 P[i][j]`. Baja quiere decir que desde i siempre vas al mismo sitio; alta, que a cualquiera.
- **Tasa de entropía de la cadena:** `H = Σ_i π_i·H_i`, lo predecible que es tu día en general. Si baja semana a semana, los días se están volviendo más estructurados.
- **Fuente:** `edges`. Ya se puede calcular hoy, pero solo tiene sentido como tendencia, comparando semanas, y eso necesita fechas en las transiciones (`events.jsonl`).

## 7. Ciclos de distracción

- Contar las idas y vueltas `A→B→A`, en especial las que pasan por Gaming o por "ninguno", y las cadenas de tramos cortos (menos de 10 min) seguidos.
- Indicador semanal: número de bucles y tiempo que se pierde en ellos.
- **Necesita** la secuencia (`stint`).

## 8. Modelo oculto de Markov (HMM) sobre la detección

La detección cada 3 minutos encaja con un HMM:

| Pieza del HMM | En YourHarness |
|---|---|
| Estado oculto | en qué estás trabajando de verdad |
| Observación | lo que está abierto: el veredicto de Jev/Haiku y el `encaje` determinista de cada `plan` |
| Transiciones | la matriz P (sección 1), por franja horaria si existe (sección 9) |
| Emisiones | las probabilidades de Jev (Choice) por ambiente |

- **Viterbi / forward:** suaviza la detección. Una pestaña suelta no dispara el aviso si el historial dice que ese salto casi nunca ocurre. Así hay menos avisos en falso y no saltan por una lectura aislada. Regla práctica: ofrecer el cambio solo si la probabilidad posterior supera el umbral (hoy `SURE = 0.6` sobre una sola lectura).
- **Tiempo fuera de foco:** la suma del tiempo en que el estado detectado es distinto del ambiente encendido. Es más honesto que el tiempo declarado.
- **Calibración:** con los eventos `offer` (sí/no) se puede comprobar si la confianza de Jev está calibrada (por ejemplo, ¿se acepta el 80 % de los avisos que dicen 80 %?) y ajustar el umbral.
- **Necesita** los `detect` y los `offer`.

## 9. Cadena según la hora (predicción)

La cadena no es homogénea: StartDay es por la mañana y Gaming por la noche. Conviene una matriz `P_h` por franja (mañana, mediodía, tarde, noche, o por hora con suavizado hacia la P global).

- **Siguiente ambiente probable** a esta hora y desde el ambiente actual: `argmax_j P_h[i][j]`.
- **Precalentar:** si a las 9:30 lo normal es pasar a Trabajo, levantar Docker antes.
- **Días atípicos:** la log-verosimilitud de la secuencia del día frente al modelo. Si es baja, el día se salió de lo normal.
- **Necesita** la hora de cada transición (`stint`).

---

## Qué mostrar en ClaudeMaxxing (propuesta)

Una pestaña "Estadísticas" dentro de Ambientes, junto al grafo actual:

1. El mapa de calor de P, con las filas de pocos datos atenuadas.
2. El reparto de tiempo **real** (de `time`) frente al **proyectado** (π·d) frente al **objetivo**.
3. La duración media del foco por ambiente y su tendencia semanal.
4. La entropía semanal y los bucles de distracción de la semana.
5. El siguiente ambiente probable según la hora.
6. El tiempo fuera de foco (cuando exista el HMM).

## Orden sugerido

1. `events.jsonl` (sección 0): pocas líneas en `env.js` y en la bandeja. Hay que hacerlo ya para que los datos se acumulen.
2. Con lo que ya hay: P, π, duración media y entropía (1, 2, 3 y 6), como funciones puras en `env.js` (`node env.js stats [--json]`) con casos en `plan.test.js`, y ClaudeMaxxing que solo las lee.
3. Tras unas semanas de eventos: el día absorbente, los ciclos y la cadena por hora (5, 7 y 9).
4. Por último, el HMM (8), cuando haya bastantes `detect`/`offer` para calibrar.
