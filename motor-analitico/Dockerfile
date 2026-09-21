# Contenedor del motor analítico.
#
# NO SE USA TODAVÍA. Los workflows de GitHub Actions instalan las
# dependencias con pip directamente, que es más rápido con la caché del
# runner y no requiere un registro de imágenes.
#
# Existe por dos razones concretas:
#
# 1. Es la salida de emergencia. Si el presupuesto de GitHub Actions se
#    queda corto (2.000 min/mes en repositorio privado), la migración
#    natural es Google Cloud Run, que escala a cero y factura por uso.
#    Con este fichero, ese cambio es el disparador, no una reescritura.
#
# 2. Fija la versión de Python de forma verificable. El README de la
#    Fase 1 lo explica: pandas-ta no se actualiza desde 2021 y parte del
#    stack científico falla al compilar numpy en 3.13/3.14. Un
#    `FROM python:3.12-slim` es más difícil de romper por accidente que
#    una línea en un YAML.

FROM python:3.12-slim

WORKDIR /motor

# Las dependencias en su propia capa: cambian mucho menos que el código,
# así que reconstruir tras editar un indicador no vuelve a compilar nada.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Sin CMD por defecto a propósito: este contenedor tiene dos usos y
# ninguno es "el principal".
#
#   ETL:      docker run <img> python etl.py --clase accion
#   servicio: docker run <img> uvicorn servicio_interno:app --port 8001
#
# Un CMD apuntando a uno de los dos invitaría a ejecutar el equivocado.
